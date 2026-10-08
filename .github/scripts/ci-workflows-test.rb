#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require 'yaml'

class CIWorkflowsTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)

  def setup
    @ci = YAML.load_file(File.join(ROOT, '.github/workflows/ci.yml'))
    @aggregate = @ci.fetch('jobs').fetch('result').fetch('steps').first.fetch('run')
    @needs = {
      'changes' => { 'result' => 'success', 'outputs' => { 'agent' => 'true', 'swift' => 'true', 'website' => 'true', 'targets' => '[]' } },
      'agent-core' => { 'result' => 'success' }, 'swift' => { 'result' => 'success' }, 'website' => { 'result' => 'success' }
    }
  end

  def test_full_check_success
    assert_result true
  end

  def test_documentation_skip_success
    %w[agent swift website].each { |key| @needs['changes']['outputs'][key] = 'false' }
    %w[agent-core swift website].each { |key| @needs[key]['result'] = 'skipped' }
    assert_result true
  end

  def test_explicit_full_and_partial_skip_use_real_unskipped_results
    @needs['changes']['outputs']['targets'] = '["swift"]'
    @needs['swift']['result'] = 'skipped'
    assert_result true
    @needs['agent-core']['result'] = 'failure'
    assert_result false
    @needs['changes']['outputs']['targets'] = '["agent","swift","website"]'
    %w[agent-core swift website].each { |key| @needs[key]['result'] = 'skipped' }
    assert_result true
  end

  def test_missing_or_failed_gate_cannot_make_dependents_green
    %w[failure cancelled skipped].each do |result|
      @needs['changes']['result'] = result
      assert_result false
    end
    @needs.delete('changes')
    assert_result false
  end

  def test_failure_cancellation_or_unexpected_skip_is_rejected
    %w[failure cancelled skipped].each do |result|
      @needs['swift']['result'] = result
      assert_result false
    end
  end

  def test_missing_or_malformed_outputs_are_rejected
    ['', 'yes', nil].each do |value|
      @needs['changes']['outputs']['agent'] = value
      assert_result false
    end
    @needs['changes']['outputs']['agent'] = 'true'
    ['null', '{}', 'invalid', '[1]'].each do |value|
      @needs['changes']['outputs']['targets'] = value
      assert_result false
    end
  end

  def test_ci_always_creates_a_result_and_preserves_xcode_and_smoke_checks
    assert_equal 'always()', @ci.fetch('jobs').fetch('result').fetch('if')
    assert_equal %w[changes agent-core swift website], @ci.fetch('jobs').fetch('result').fetch('needs')
    assert_equal 'xcode-27', @ci.fetch('jobs').fetch('swift').fetch('runs-on')
    commands = @ci.fetch('jobs').fetch('swift').fetch('steps').filter_map { |step| step['run'] }.join("\n")
    assert_includes commands, 'make build-package'
    assert_includes commands, 'codesign --verify --deep --strict'
    assert_includes commands, 'agent.status'
    assert_includes commands, 'npm test --prefix macos/AnotherYou/MarkdownRenderer'
    website = @ci.fetch('jobs').fetch('website').fetch('steps').filter_map { |step| step['run'] }.join("\n")
    assert_includes website, 'node --test website/i18n.test.cjs'
    gates = @ci.fetch('jobs').fetch('changes').fetch('steps')
    assert_operator gates.index { |step| step['id'] == 'skip' }, :<, gates.index { |step| step['id'] == 'paths' }
  end

  def test_remote_actions_are_sha_pinned_and_workflows_do_not_store_checkout_credentials
    paths = Dir.glob(File.join(ROOT, '.github/{workflows/*.yml,actions/**/action.yml}'))
    paths.each do |path|
      walk(YAML.load_file(path)) do |node|
        next unless node.is_a?(Hash) && node['uses']

        reference = node.fetch('uses')
        assert_match(/@[0-9a-f]{40}\z/, reference, path) unless reference.start_with?('./')
        assert_equal false, node.fetch('with').fetch('persist-credentials'), path if reference.start_with?('actions/checkout@')
      end
    end
  end

  def test_manifest_matches_the_actual_workflow_names
    manifest = JSON.parse(File.read(File.join(ROOT, '.github/ci-skip.json')))
    manifest.fetch('workflows').each do |entry|
      workflow = YAML.load_file(File.join(ROOT, '.github/workflows', entry.fetch('file')))
      assert_equal entry.fetch('name'), workflow.fetch('name')
      events = workflow['on'] || workflow[true]
      assert events.key?('pull_request'), entry.fetch('file')
      refute events.fetch('pull_request', {}).to_h.key?('paths'), entry.fetch('file')
      refute events.fetch('pull_request', {}).to_h.key?('paths-ignore'), entry.fetch('file')
    end
  end

  def test_bootstrap_without_default_resolver_runs_all_checks_and_cleans_its_checkout
    action = YAML.load_file(File.join(ROOT, '.github/actions/ci-skip-gate/action.yml'))
    steps = action.fetch('runs').fetch('steps')
    assert_equal '${{ github.event.repository.default_branch }}', steps.first.fetch('with').fetch('ref')
    resolve = steps.find { |step| step['id'] == 'resolve' }.fetch('run')
    cleanup = steps.find { |step| step['if'] == 'always()' }.fetch('run')
    Dir.mktmpdir('another-you-ci-bootstrap-') do |directory|
      FileUtils.mkdir_p(File.join(directory, '.ci-trusted'))
      output_file = File.join(directory, 'outputs')
      output, status = Open3.capture2e({ 'GITHUB_OUTPUT' => output_file }, 'bash', '-e', '-o', 'pipefail', '-c', resolve, chdir: directory)
      assert status.success?, output
      assert_equal "skip=false\ntargets=[]\nhead-sha=\n", File.read(output_file)
      output, status = Open3.capture2e('bash', '-e', '-c', cleanup, chdir: directory)
      assert status.success?, output
      refute File.exist?(File.join(directory, '.ci-trusted'))
    end
  end

  def test_skip_processor_only_uses_default_branch_and_cannot_write_checks
    processor = YAML.load_file(File.join(ROOT, '.github/workflows/ci-skip.yml'))
    job = processor.fetch('jobs').fetch('apply')
    assert_equal '${{ github.event.repository.default_branch }}', job.fetch('steps').first.fetch('with').fetch('ref')
    refute job.fetch('permissions').key?('checks')
    refute job.fetch('permissions').key?('statuses')
    assert_equal 'read', job.fetch('permissions').fetch('contents')
    assert_includes job.fetch('if'), "startsWith(github.event.comment.body, '<!-- another-you-ci-skip -->')"
    assert_includes job.fetch('if'), "github.event.comment.user.type == 'Bot'"
    deleted = job.fetch('steps').last.fetch('env').fetch('CI_SKIP_DELETED_SUMMARY')
    assert_includes deleted, "startsWith(github.event.comment.body, '<!-- another-you-ci-skip -->')"
    assert_includes deleted, "github.event.comment.user.type == 'Bot'"
  end

  private

  def assert_result(expected)
    output, status = Open3.capture2e({ 'CI_NEEDS' => JSON.generate(@needs) }, 'bash', '-e', '-o', 'pipefail', '-c', @aggregate, chdir: ROOT)
    assert_equal expected, status.success?, output
  end

  def walk(value, &block)
    yield value
    case value
    when Hash then value.each_value { |child| walk(child, &block) }
    when Array then value.each { |child| walk(child, &block) }
    end
  end
end
