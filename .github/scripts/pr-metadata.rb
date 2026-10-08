#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'optparse'

module PullRequestMetadata
  REQUIRED_SECTIONS = ['Summary', 'PR Type', 'Validation', 'Risk and Rollback', 'Related Issue'].freeze
  COMMENT = /<!--.*?(?:-->|\z)/m
  FENCE = /\A {0,3}(`{3,}|~{3,})/
  PLACEHOLDER = /\A(?:tbd|todo|n\/?a|none|placeholder|待补充|暂无|<[^>]+>)\z/i
  CLOSING_REFERENCE = %r{\A(?:[-*][[:space:]]+)?(?:closes|closed|close|fixes|fixed|fix|resolves|resolved|resolve)[[:space:]]+(?:(?:[A-Za-z0-9._-]+/[A-Za-z0-9._-]+)?#([1-9]\d*)|https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/issues/([1-9]\d*))\.?\z}i

  class ContractError < StandardError; end

  class Contract
    def self.load(path)
      new(JSON.parse(File.read(path)))
    rescue JSON::ParserError => error
      raise ContractError, "#{path}: invalid JSON (#{error.message})"
    end

    def initialize(document)
      @types = document.fetch('types')
      @issue_label = document.fetch('issueLabel')
      @needs_more_info = document.fetch('needsMoreInfoLabel')
      raise ContractError, 'contract declares no types' if @types.empty?
      raise ContractError, 'contract declares duplicate types' if type_names.uniq != type_names
    end

    def type_names
      @types.map { |entry| entry.fetch('type') }
    end

    def canonical_type(value)
      type_names.find { |type| type == value }
    end

    def label_for(value)
      @types.find { |entry| entry['type'] == value }&.fetch('label')
    end

    def issue_label
      @issue_label.fetch('label')
    end

    def needs_more_info_label
      @needs_more_info.fetch('label')
    end

    def managed_labels
      (@types + [@issue_label, @needs_more_info]).map { |entry| entry.slice('label', 'color', 'description') }
    end

    def managed_label_names
      managed_labels.map { |entry| entry['label'] }
    end
  end

  def self.sections(body, duplicates: [])
    current = nil
    fence = nil
    body.to_s.gsub("\r\n", "\n").gsub(COMMENT, '').each_line.each_with_object({}) do |raw_line, map|
      line = raw_line.chomp
      if fence
        fence = nil if line.match?(/\A {0,3}#{Regexp.escape(fence[0])}{#{fence.length},}[[:space:]]*\z/)
        next
      end
      marker = line[FENCE, 1]
      if marker
        fence = marker
        next
      end
      next if line.match?(/\A(?: {4}|\t| {0,3}>)/)

      # Only visible, top-level metadata counts; examples cannot complete a PR.
      heading = line.match(/\A##[[:space:]]+(.+?)[[:space:]]*\z/)
      if heading
        current = heading[1]
        duplicates << current if map.key?(current)
        map[current] ||= []
      elsif line.match?(/\A\#[[:space:]]+/)
        current = nil
      elsif current
        map[current] << line
      end
    end
  end

  def self.field_values(lines, key)
    pattern = /\A {0,3}-[[:space:]]*#{Regexp.escape(key)}:[[:space:]]*(.*?)[[:space:]]*\z/i
    Array(lines).filter_map { |line| pattern.match(line)&.[](1) }
  end

  def self.meaningful?(value)
    visible = value.to_s.strip.gsub(/\A(?:[-*+]|\d+[.)])\s*/, '')
                   .gsub(/\A\[[ xX]\]\s*/, '').gsub(/[*_`]/, '').strip
    visible.match?(/[[:alnum:]]/) && !PLACEHOLDER.match?(visible)
  end

  def self.parse(body, contract)
    duplicates = []
    parsed = sections(body, duplicates: duplicates)
    type_values = field_values(parsed['PR Type'], 'Type')
    type = contract.canonical_type(type_values.first) if type_values.length == 1
    related = Array(parsed['Related Issue']).map(&:strip).reject(&:empty?)
    references = related.filter_map { |line| CLOSING_REFERENCE.match(line) }
    {
      'type' => type,
      'typeLabel' => type && contract.label_for(type),
      'issues' => references.flat_map { |match| match.captures.compact }.map(&:to_i).uniq.sort,
      'relatedLines' => related,
      'relatedReferences' => references.length,
      'sections' => parsed,
      'duplicates' => duplicates.uniq
    }
  end

  def self.title_pattern(contract)
    types = contract.type_names.map { |type| Regexp.escape(type) }.join('|')
    /\A(#{types})(?:\([a-z0-9][a-z0-9-]*\))?!?: ([!-~][ -~]*)\z/
  end

  def self.labels(metadata, contract)
    result = [metadata['typeLabel']].compact
    result << contract.issue_label unless metadata['issues'].empty?
    result
  end

  def self.analyze(title:, body:, contract:)
    metadata = parse(body, contract)
    errors = validate(title: title, body: body, contract: contract, metadata: metadata)
    desired = labels(metadata, contract)
    desired << contract.needs_more_info_label unless errors.empty?
    metadata.slice('type', 'typeLabel', 'issues').merge(
      'valid' => errors.empty?, 'errors' => errors,
      'labels' => desired, 'managedLabels' => contract.managed_label_names
    )
  end

  def self.validate(title:, body:, contract:, metadata: nil)
    errors = []
    title_match = title_pattern(contract).match(title.to_s.strip)
    unless title_match && title_match[2].match?(/[A-Za-z]/) && meaningful?(title_match[2])
      errors << 'Title must be an English Conventional Commit subject, for example "ci(github): validate contribution metadata".'
      errors << "Allowed types: #{contract.type_names.join(', ')}. Optional scope uses lowercase letters, digits, and hyphens."
    end

    metadata ||= parse(body, contract)
    missing = REQUIRED_SECTIONS.reject { |section| metadata['sections'].key?(section) }
    errors << "Missing required section(s): #{missing.map { |section| "## #{section}" }.join(', ')}." unless missing.empty?
    metadata['duplicates'].each do |section|
      errors << "Section \"## #{section}\" must appear exactly once." if REQUIRED_SECTIONS.include?(section)
    end
    unless Array(metadata['sections']['Summary']).any? { |line| meaningful?(line) }
      errors << 'Summary must include a non-empty description of the problem and final behavior.'
    end
    errors.concat(validate_type(metadata, contract, title_match))
    errors.concat(validate_validation(metadata))
    errors.concat(validate_risk_and_rollback(metadata))
    errors.concat(validate_related_issue(metadata))
    errors
  end

  def self.validate_type(metadata, contract, title_match)
    values = field_values(metadata['sections']['PR Type'], 'Type')
    unless values.length == 1 && contract.canonical_type(values.first)
      return ["PR Type must declare exactly one \"- Type: <type>\" using: #{contract.type_names.join(', ')}."]
    end
    return [] if title_match.nil? || title_match[1] == values.first

    ['PR Type does not match the title type.']
  end

  def self.validate_validation(metadata)
    lines = metadata['sections']['Validation']
    return [] if lines.nil?

    entries = []
    errors = []
    lines.each do |line|
      if line.match?(/\A {0,3}-[[:space:]]*Status:/i)
        entries << []
      elsif entries.empty? && line.match?(/\A {0,3}-[[:space:]]*(?:Command|Result|Reason):/i)
        errors << 'Validation fields must follow their own Status entry.'
      end
      entries.last << line unless entries.empty?
    end
    return errors + ['Validation must declare a Status: passed, failed, or not run.'] if entries.empty?

    errors + entries.each_with_index.flat_map do |entry, index|
      label = "Validation entry #{index + 1}"
      status = field_values(entry, 'Status').first
      unless ['passed', 'failed', 'not run'].include?(status)
        next ["#{label} must declare one exact status: passed, failed, or not run."]
      end

      required = status == 'not run' ? ['Reason'] : %w[Command Result]
      %w[Command Result Reason].filter_map do |key|
        values = field_values(entry, key)
        if values.length > 1
          "#{label} must declare at most one #{key} field, including empty entries."
        elsif required.include?(key) && !meaningful?(values.first)
          "#{label} must include a non-empty #{key} field."
        end
      end
    end
  end

  def self.validate_risk_and_rollback(metadata)
    lines = metadata['sections']['Risk and Rollback']
    return [] if lines.nil?

    %w[Risk Rollback].filter_map do |key|
      values = field_values(lines, key)
      unless values.length == 1 && meaningful?(values.first)
        "Risk and Rollback must declare exactly one non-empty #{key} field."
      end
    end
  end

  def self.validate_related_issue(metadata)
    lines = metadata['relatedLines']
    return [] if lines.length == 1 && lines.first.casecmp('none').zero?
    return [] if !lines.empty? && metadata['relatedReferences'] == lines.length

    ['Related Issue must use one closing reference per line, such as "Closes #123", or exactly "None".']
  end
end

if $PROGRAM_NAME == __FILE__
  options = { manifest: File.expand_path('../pr-automation.json', __dir__) }
  parser = OptionParser.new do |opts|
    opts.banner = 'Usage: pr-metadata.rb <validate|json|labels> [options]'
    opts.on('--manifest PATH', 'Label contract path') { |value| options[:manifest] = value }
    opts.on('--title-file PATH', 'File holding the pull request title') { |value| options[:title_file] = value }
    opts.on('--body-file PATH', 'File holding the pull request body') { |value| options[:body_file] = value }
  end

  begin
    argv = parser.parse(ARGV)
    command = argv.shift
    raise PullRequestMetadata::ContractError, 'Unexpected command arguments.' unless argv.empty?
    contract = PullRequestMetadata::Contract.load(options[:manifest])
    if command == 'labels'
      puts JSON.pretty_generate(contract.managed_labels)
    elsif %w[json validate].include?(command)
      unless options[:title_file] && options[:body_file]
        raise PullRequestMetadata::ContractError, '--title-file and --body-file are required.'
      end
      report = PullRequestMetadata.analyze(
        title: File.read(options[:title_file]), body: File.read(options[:body_file]), contract: contract
      )
      if command == 'json'
        puts JSON.pretty_generate(report)
      elsif report['valid']
        puts 'Pull request metadata is valid.'
      else
        report['errors'].each { |error| warn error }
        warn 'See CONTRIBUTING.md and .github/PULL_REQUEST_TEMPLATE.md for the required title and fields.'
        exit 1
      end
    else
      warn parser.banner
      exit 1
    end
  rescue PullRequestMetadata::ContractError, OptionParser::ParseError, KeyError, SystemCallError, JSON::ParserError, TypeError => error
    warn error.message
    exit 1
  end
end
