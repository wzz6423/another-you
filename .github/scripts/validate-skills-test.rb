#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'
require_relative 'validate-skills'

class SkillValidatorTest < Minitest::Test
  def setup
    @temporary_directory = Pathname.new(Dir.mktmpdir('another-you-skills-test-'))
    @root = @temporary_directory / 'repository'
    @skills = @root / 'skills'
    @skills.mkpath
  end

  def teardown
    FileUtils.remove_entry(@temporary_directory)
  end

  def test_accepts_repository_guides_and_sibling_skills
    write_skill('first-skill', '[Guide](../../CONTRIBUTING.md) [Other](../second-skill/SKILL.md)')
    write_skill('second-skill', '[Help](https://example.com) [Section](#usage)')
    (@root / 'CONTRIBUTING.md').write('# Guide')
    assert_validation true
  end

  def test_accepts_supported_metadata_and_encoded_local_paths
    write_skill('valid-skill', '[Notes](<references/My%20Notes.md#usage>)', <<~YAML)
      name: valid-skill
      description: A useful skill.
      license: MIT
      compatibility: Ruby is required.
      allowed-tools: Read
      metadata:
        author: Test
        version: "1"
    YAML
    directory = @skills / 'valid-skill/references'
    directory.mkpath
    (directory / 'My Notes.md').write('# Usage')
    assert_validation true
  end

  def test_rejects_missing_frontmatter_and_empty_body
    file = write_skill('valid-skill', '')
    assert_validation false
    file.write('# A skill without frontmatter')
    assert_validation false
  end

  def test_rejects_invalid_fields_and_name_mismatch
    write_skill('valid-skill', '# Usage', <<~YAML)
      name: bad--name
      description: ""
      unexpected: value
      metadata:
        version: 1
    YAML
    assert_validation false
  end

  def test_rejects_missing_and_escaping_references
    write_skill('valid-skill', '[Missing](missing.md) [Outside](../../../outside.md)')
    (@temporary_directory / 'outside.md').write('# Outside')
    assert_validation false
  end

  def test_rejects_symlink_reference_outside_repository
    file = write_skill('valid-skill', '[Outside](outside.md)')
    outside = @temporary_directory / 'outside.md'
    outside.write('# Outside')
    File.symlink(outside, file.dirname / 'outside.md')
    assert_validation false
  end

  def test_rejects_skill_file_outside_repository
    file = write_skill('valid-skill', '# Usage')
    outside = @temporary_directory / 'outside.md'
    FileUtils.mv(file, outside)
    File.symlink(outside, file)
    assert_validation false
  end

  def test_rejects_yaml_objects_and_aliases
    write_skill('valid-skill', '# Usage', "name: valid-skill\ndescription: !ruby/object:Object {}\n")
    assert_validation false
    write_skill('valid-skill', '# Usage', "name: &name valid-skill\ndescription: *name\n")
    assert_validation false
  end

  def test_rejects_empty_skills_directory
    assert_validation false
  end

  private

  def write_skill(name, body, frontmatter = nil)
    directory = @skills / name
    directory.mkpath
    file = directory / 'SKILL.md'
    frontmatter ||= "name: #{name}\ndescription: A useful skill.\n"
    file.write("---\n#{frontmatter}---\n\n#{body}\n")
    file
  end

  def assert_validation(expected)
    result = nil
    _output, errors = capture_io { result = SkillValidator.new(@skills).run }
    assert_equal expected, result, errors
  end
end
