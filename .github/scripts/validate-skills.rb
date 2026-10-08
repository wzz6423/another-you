#!/usr/bin/env ruby
# frozen_string_literal: true

require 'pathname'
require 'uri'
require 'yaml'

class SkillValidator
  ALLOWED_FIELDS = %w[name description license compatibility metadata allowed-tools].freeze
  NAME_PATTERN = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
  LINK_PATTERN = /!?\[[^\]\n]*\]\(\s*(?:<([^>\n]+)>|([^\s)]+))[^\n]*?\)/

  def initialize(skills_directory)
    @skills_directory = Pathname.new(skills_directory).expand_path
    @repository_root = @skills_directory.parent.realpath
    @skills_directory = @repository_root / @skills_directory.basename
    @errors = []
  end

  def run
    unless @skills_directory.directory? && contained_by?(@skills_directory.realpath, @repository_root)
      warn 'A skills directory inside the repository is required.'
      return false
    end

    directories = @skills_directory.children.select(&:directory?).sort
    @errors << 'No skill directories found.' if directories.empty?
    directories.each { |directory| validate_skill(directory) }
    @errors.each { |error| warn error }
    puts "Validated #{directories.length} skill(s)." if @errors.empty?
    @errors.empty?
  end

  private

  def error(path, message)
    @errors << "#{path.relative_path_from(@repository_root)}: #{message}"
  end

  def validate_skill(directory)
    file = directory / 'SKILL.md'
    unless file.file? && contained_by?(file.realpath, @repository_root)
      error(file, 'SKILL.md must exist inside the repository.')
      return
    end

    content = file.read(encoding: 'UTF-8')
    match = content.match(/\A---[ \t]*\r?\n(.*?)\r?\n---[ \t]*\r?\n(.*)\z/m)
    unless match
      error(file, 'YAML frontmatter is missing or malformed.')
      return
    end

    metadata = YAML.safe_load(match[1], permitted_classes: [], permitted_symbols: [], aliases: false)
    unless metadata.is_a?(Hash)
      error(file, 'Frontmatter must be a mapping.')
      return
    end

    validate_fields(file, directory.basename.to_s, metadata)
    error(file, 'Markdown body must not be empty.') if match[2].strip.empty?
    validate_links(file, match[2])
  rescue EncodingError, ArgumentError, Psych::Exception => exception
    error(file, "Invalid skill: #{exception.message.lines.first.strip}")
  end

  def validate_fields(file, directory_name, metadata)
    unknown = metadata.keys.reject { |key| key.is_a?(String) && ALLOWED_FIELDS.include?(key) }
    error(file, "Unsupported frontmatter fields: #{unknown.join(', ')}.") unless unknown.empty?

    name = metadata['name']
    unless name.is_a?(String) && NAME_PATTERN.match?(name) && name.length <= 64 && name == directory_name
      error(file, 'Name must match its directory and use up to 64 lowercase letters, digits, and single hyphens.')
    end

    %w[description license compatibility allowed-tools].each do |key|
      next if key != 'description' && !metadata.key?(key)

      value = metadata[key]
      unless value.is_a?(String) && !value.strip.empty?
        error(file, "#{key} must be a non-empty string.")
        next
      end
      limit = { 'description' => 1024, 'compatibility' => 500 }[key]
      error(file, "#{key} must contain at most #{limit} characters.") if limit && value.length > limit
    end

    return unless metadata.key?('metadata')

    values = metadata['metadata']
    unless values.is_a?(Hash) && values.all? { |key, value| key.is_a?(String) && value.is_a?(String) }
      error(file, 'Metadata must be a mapping of strings to strings.')
    end
  end

  def validate_links(file, body)
    body.scan(LINK_PATTERN) do |angle_path, plain_path|
      destination = angle_path || plain_path
      next if destination.start_with?('#', '//') || destination.match?(/\A[a-z][a-z0-9+.-]*:/i)

      local_path = URI::DEFAULT_PARSER.unescape(destination.split(/[?#]/, 2).first)
      next if local_path.empty?

      target = (file.dirname / local_path).cleanpath
      # 项目 Skill 会引用根目录指南；边界是仓库，而非单个 Skill 目录。
      unless contained_by?(target, @repository_root) && target.exist? && contained_by?(target.realpath, @repository_root)
        error(file, "Local reference must resolve to an existing repository path: #{destination}")
      end
    end
  end

  def contained_by?(path, root)
    relative = path.relative_path_from(root)
    !relative.absolute? && relative.each_filename.first != '..'
  rescue ArgumentError
    false
  end
end

if $PROGRAM_NAME == __FILE__
  exit(SkillValidator.new(Pathname.new(__dir__).join('../../skills')).run ? 0 : 1)
end
