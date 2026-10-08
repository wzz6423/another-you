#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require 'uri'

module ContributionAutomation
  class Error < StandardError; end
  class APIError < Error; end

  class GitHub
    def request(method, path, payload = nil, paginate: false)
      command = ['gh', 'api', '--method', method, path]
      command.concat(%w[--paginate --slurp]) if paginate
      command.concat(%w[--input -]) if payload
      output, diagnostic, status = Open3.capture3(*command, stdin_data: payload ? JSON.generate(payload) : '')
      raise APIError, "GitHub API #{method} #{path} failed: #{diagnostic.strip}" unless status.success?

      output.empty? ? nil : JSON.parse(output)
    end

    def list(path)
      pages = request('GET', "#{path}?per_page=100", paginate: true)
      raise Error, "Expected paginated arrays from #{path}" unless pages.is_a?(Array) && pages.all? { |page| page.is_a?(Array) }

      pages.flatten(1)
    end
  end

  class MetadataReader
    def initialize(kind, temporary_root = nil)
      @script = File.join(__dir__, "#{kind}-metadata.rb")
      @temporary_root = temporary_root
    end

    def read(resource)
      Dir.mktmpdir('another-you-automation-', @temporary_root) do |directory|
        title = File.join(directory, 'title.txt')
        body = File.join(directory, 'body.md')
        File.write(title, resource.fetch('title'))
        File.write(body, resource['body'].to_s)
        [parse('json', '--title-file', title, '--body-file', body), parse('labels')]
      end
    end

    private

    def parse(*arguments)
      output, diagnostic, status = Open3.capture3(RbConfig.ruby, @script, *arguments)
      raise Error, "Metadata parser failed: #{diagnostic.strip}" unless status.success?

      JSON.parse(output)
    end
  end

  class Runner
    def initialize(kind, env: ENV, api: GitHub.new, metadata_reader: nil)
      raise Error, 'Contribution kind must be issue or pr.' unless %w[issue pr].include?(kind)

      @kind = kind
      @env = env
      @api = api
      repository = env.fetch('GITHUB_REPOSITORY')
      number = env.fetch('CONTRIBUTION_NUMBER')
      unless repository.match?(%r{\A[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9_.-]+\z}) && !%w[. ..].include?(repository.split('/').last)
        raise Error, 'GITHUB_REPOSITORY must be owner/repository.'
      end
      raise Error, 'Contribution number must be a positive integer.' unless number.match?(/\A[1-9][0-9]*\z/)

      @repository = "repos/#{repository}"
      @item = "#{@repository}/issues/#{number}"
      @resource = kind == 'pr' ? "#{@repository}/pulls/#{number}" : @item
      @metadata_reader = metadata_reader || MetadataReader.new(kind, env['RUNNER_TEMP'])
    end

    def run
      # 排队的旧事件也必须使用当前内容，不能用事件快照覆盖后续编辑的标签与反馈。
      resource = @api.request('GET', @resource)
      return { 'skipped' => 'closed' } if resource.fetch('state') == 'closed'
      raise Error, 'Expected an issue, received a pull request.' if @kind == 'issue' && resource.key?('pull_request')

      # Dependabot 不填写人工 PR 模板；清除旧格式提示，依赖检查仍交给 CI。
      if @kind == 'pr' && resource.dig('user', 'type') == 'Bot' && resource.dig('user', 'login') == 'dependabot[bot]'
        stale = label_names(@api.list("#{@item}/labels")).find { |name| name.casecmp?('needs-more-info') }
        @api.request('DELETE', "#{@item}/labels/#{encode(stale)}") if stale
        return { 'skipped' => 'dependabot' }
      end

      metadata, definitions = @metadata_reader.read(resource)
      validate_contract!(metadata, definitions)
      repository_labels = label_names(@api.list("#{@repository}/labels"))
      current_labels = label_names(@api.list("#{@item}/labels"))
      bot = resource.fetch('user')['type'] == 'Bot' ||
            resource.fetch('user').fetch('login').end_with?('[bot]') || @env.fetch('GITHUB_ACTOR', '').end_with?('[bot]')
      comments = bot ? [] : @api.list("#{@item}/comments")

      ensure_labels(definitions, repository_labels)
      synchronize_labels(metadata, current_labels)
      result = bot ? 'skipped-bot' : synchronize_comment(metadata, comments)
      { 'valid' => metadata.fetch('valid'), 'labels' => metadata.fetch('labels'), 'comment' => result }
    end

    private

    def validate_contract!(metadata, definitions)
      unless [true, false].include?(metadata['valid']) && %w[errors labels managedLabels].all? do |key|
        metadata[key].is_a?(Array) && metadata[key].all? { |value| value.is_a?(String) }
      end
        raise Error, 'Invalid metadata contract.'
      end
      unless definitions.is_a?(Array) && definitions.all? do |entry|
        entry.is_a?(Hash) && %w[label color description].all? { |key| entry[key].is_a?(String) }
      end
        raise Error, 'Invalid label definitions.'
      end
      unless (metadata.fetch('labels') - metadata.fetch('managedLabels')).empty? &&
             (metadata.fetch('managedLabels') - definitions.map { |entry| entry.fetch('label') }).empty?
        raise Error, 'Metadata may only manage declared contract labels.'
      end
    end

    def label_names(labels)
      labels.map { |label| label.fetch('name') }
    end

    def ensure_labels(definitions, existing)
      definitions.each do |entry|
        next if existing.any? { |name| name.casecmp?(entry.fetch('label')) }

        payload = { 'name' => entry.fetch('label'), 'color' => entry.fetch('color'), 'description' => entry.fetch('description') }
        begin
          @api.request('POST', "#{@repository}/labels", payload)
        rescue APIError => failure
          # 不同 Issue/PR 可能同时创建同一标签；仅在重查确认已存在时接受冲突。
          begin
            label = @api.request('GET', "#{@repository}/labels/#{encode(entry.fetch('label'))}")
            raise failure unless label.fetch('name').casecmp?(entry.fetch('label'))
          rescue APIError, KeyError
            raise failure
          end
        end
      end
    end

    def synchronize_labels(metadata, current)
      desired = metadata.fetch('labels')
      managed_names = metadata.fetch('managedLabels').map(&:downcase)
      desired_names = desired.map(&:downcase)
      current.select { |label| managed_names.include?(label.downcase) && !desired_names.include?(label.downcase) }.each do |label|
        @api.request('DELETE', "#{@item}/labels/#{encode(label)}")
      end
      missing = desired.reject { |label| current.any? { |name| name.casecmp?(label) } }
      @api.request('POST', "#{@item}/labels", { 'labels' => missing }) unless missing.empty?
    end

    def synchronize_comment(metadata, comments)
      marker = "<!-- another-you-#{@kind}-automation -->"
      existing = comments.find do |comment|
        comment.dig('user', 'login') == 'github-actions[bot]' && comment['body'].to_s.start_with?(marker)
      end
      body = feedback(metadata, marker)
      return 'unchanged' if existing && existing['body'] == body

      if existing
        @api.request('PATCH', "#{@repository}/issues/comments/#{existing.fetch('id')}", { 'body' => body })
        'updated'
      else
        @api.request('POST', "#{@item}/comments", { 'body' => body })
        'created'
      end
    end

    def feedback(metadata, marker)
      noun = @kind == 'issue' ? 'issue' : 'pull request'
      lines = [marker, '', 'Thanks for contributing to Another You.', '']
      if metadata.fetch('valid')
        lines << "The #{noun} title and required fields pass the format check."
        lines << 'CI results and code review are tracked separately.' if @kind == 'pr'
      else
        lines << "Please edit this #{noun} to address the following:"
        lines << ''
        lines.concat(metadata.fetch('errors').map { |error| "- #{error}" })
      end
      base = "#{@env.fetch('GITHUB_SERVER_URL', 'https://github.com')}/#{@env.fetch('GITHUB_REPOSITORY')}/blob/#{encode(@env.fetch('GITHUB_DEFAULT_BRANCH', 'main'))}"
      lines.concat(['', "[Contribution guide](#{base}/CONTRIBUTING.md) · [简体中文](#{base}/CONTRIBUTING.zh-CN.md)",
                    '', 'This comment updates after edits.'])
      lines.join("\n")
    end

    def encode(value)
      URI.encode_www_form_component(value).gsub('+', '%20')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    raise ContributionAutomation::Error, 'Usage: contribution-automation.rb <issue|pr>' unless ARGV.length == 1

    puts JSON.generate(ContributionAutomation::Runner.new(ARGV.first).run)
  rescue ContributionAutomation::Error, JSON::ParserError, KeyError, SystemCallError => error
    warn error.message
    exit 1
  end
end
