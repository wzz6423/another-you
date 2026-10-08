#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative 'ci-paths'

class CIPathsTest < Minitest::Test
  ALL = { 'agent' => true, 'swift' => true, 'website' => true }.freeze
  NONE = { 'agent' => false, 'swift' => false, 'website' => false }.freeze

  def test_documentation_whitelist
    %w[README.md CONTRIBUTING.zh-CN.md SECURITY.md docs/releasing.md docs/figure.png agent-core/README.zh-CN.md macos/AnotherYou/README.md website/README.md release/README.md output/imagegen/another-you-logo-v8/prompts.md output/imagegen/another-you-logo-v8/another-you-dark.png].each do |path|
      assert_equal NONE, CIPaths.jobs_for([path]), path
    end
  end

  def test_cross_module_and_unknown_paths_run_everything
    %w[.github/workflows/ci.yml .github/README.md skills/another-you-release/SKILL.md AGENTS.md Makefile scripts/test-release.py agent-core/scripts/bootstrap-pi.sh release/config.json licenses/Pi-LICENSE docs/run.py output/tool.py new-component/source.ts .gitignore unexpected.md].each do |path|
      assert_equal ALL, CIPaths.jobs_for([path]), path
    end
  end

  def test_agent_changes_keep_swift_sidecar_integration
    assert_equal NONE.merge('agent' => true, 'swift' => true), CIPaths.jobs_for(['agent-core/src/cli.ts'])
    assert_equal NONE.merge('agent' => true, 'swift' => true), CIPaths.jobs_for(['agent-core/package-lock.json'])
  end

  def test_macos_source_assets_and_embedded_markdown_stay_in_build_scope
    %w[macos/AnotherYou/Package.swift macos/AnotherYou/MarkdownRenderer/markdown.mjs macos/AnotherYou/Sources/AnotherYouCore/Resources/BrandDark.png macos/AnotherYou/Sources/AnotherYouCore/Markdown/example.md].each do |path|
      assert_equal NONE.merge('swift' => true), CIPaths.jobs_for([path]), path
    end
  end

  def test_website_and_mixed_changes
    assert_equal NONE.merge('website' => true), CIPaths.jobs_for(['website/i18n.js'])
    assert_equal ALL, CIPaths.jobs_for(['README.md', 'website/i18n.js', 'agent-core/src/cli.ts'])
    assert_equal NONE, CIPaths.jobs_for([])
  end

  def test_non_pr_events_and_missing_comparison_run_everything
    %w[workflow_dispatch merge_group unknown].each { |event| assert_equal ALL, CIPaths.resolve(event, {}).fetch('jobs') }
    assert_equal ALL, CIPaths.resolve('push', { 'before' => '0' * 40, 'after' => 'a' * 40 }).fetch('jobs')
    assert_equal ALL, CIPaths.resolve('push', { 'before' => '--output=oops', 'after' => 'a' * 40 }).fetch('jobs')
    assert_equal ALL, CIPaths.resolve('pull_request', {}).fetch('jobs')
  end

  def test_missing_git_objects_fall_back_to_all_jobs
    in_repository do |directory|
      decision = CIPaths.resolve('push', { 'before' => 'a' * 40, 'after' => 'b' * 40 }, directory: directory)
      assert_equal ALL, decision.fetch('jobs')
    end
  end

  def test_renaming_code_into_docs_keeps_original_code_path
    in_repository do |directory|
      write(directory, 'agent-core/src/example.ts', 'source')
      base = commit(directory)
      FileUtils.mkdir_p(File.join(directory, 'docs'))
      FileUtils.mv(File.join(directory, 'agent-core/src/example.ts'), File.join(directory, 'docs/example.md'))
      head = commit(directory)
      assert_equal NONE.merge('agent' => true, 'swift' => true), resolve_pr(directory, base, head).fetch('jobs')
    end
  end

  def test_deleted_and_unusual_paths_are_not_lost
    in_repository do |directory|
      path = "website/含 空格\n特殊.js"
      write(directory, path, 'source')
      base = commit(directory)
      FileUtils.rm(File.join(directory, path))
      head = commit(directory)
      assert_equal NONE.merge('website' => true), resolve_pr(directory, base, head).fetch('jobs')
    end
  end

  def test_pull_request_uses_merge_base_and_push_uses_before_after
    in_repository do |directory|
      write(directory, 'README.md', 'base')
      base = commit(directory)
      write(directory, 'scripts/build-app.sh', 'base branch change')
      base_tip = commit(directory)
      git(directory, 'checkout', '--detach', base)
      write(directory, 'README.md', 'head docs')
      head = commit(directory)
      assert_equal NONE, resolve_pr(directory, base_tip, head).fetch('jobs')
      assert_equal ALL, CIPaths.resolve('push', { 'before' => base_tip, 'after' => head }, directory: directory).fetch('jobs')
    end
  end

  def test_changed_file_enumeration_has_no_api_page_limit
    in_repository do |directory|
      write(directory, 'README.md', 'base')
      base = commit(directory)
      310.times { |index| write(directory, "docs/#{index}.md", 'docs') }
      write(directory, 'website/last.js', 'source')
      head = commit(directory)
      assert_equal NONE.merge('website' => true), resolve_pr(directory, base, head).fetch('jobs')
    end
  end

  private

  def in_repository
    Dir.mktmpdir('another-you-ci-paths-') do |directory|
      git(directory, 'init', '-q')
      yield directory
    end
  end

  def write(directory, path, content)
    target = File.join(directory, path)
    FileUtils.mkdir_p(File.dirname(target))
    File.write(target, content)
  end

  def commit(directory)
    git(directory, 'add', '--all')
    git(directory, '-c', 'user.name=CI fixture', '-c', 'user.email=ci@example.invalid', '-c', 'commit.gpgsign=false', 'commit', '-qm', 'fixture')
    git(directory, 'rev-parse', 'HEAD').strip
  end

  def git(directory, *arguments)
    output, status = Open3.capture2e('git', *arguments, chdir: directory)
    assert status.success?, output
    output
  end

  def resolve_pr(directory, base, head)
    CIPaths.resolve('pull_request', { 'pull_request' => { 'base' => { 'sha' => base }, 'head' => { 'sha' => head } } }, directory: directory)
  end
end
