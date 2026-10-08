#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require 'yaml'
require_relative 'contribution-automation'

class ContributionAutomationTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  REPOSITORY = 'repos/fixture/repository'
  ITEM = "#{REPOSITORY}/issues/153"
  MARKER = '<!-- another-you-issue-automation -->'
  DEFINITIONS = %w[bug area:ci-build needs-more-info].map do |name|
    { 'label' => name, 'color' => 'd73a4a', 'description' => "Contract label #{name}" }
  end.freeze

  class MetadataFixture
    attr_accessor :metadata, :definitions
    attr_reader :resources

    def initialize
      @metadata = {
        'valid' => false, 'errors' => ['Steps to reproduce is required.'],
        'labels' => %w[bug area:ci-build needs-more-info], 'managedLabels' => %w[bug area:ci-build needs-more-info]
      }
      @definitions = DEFINITIONS
      @resources = []
    end

    def read(resource)
      @resources << resource
      [metadata, definitions]
    end
  end

  class GitHubFixture < ContributionAutomation::GitHub
    attr_accessor :resource, :labels, :repository_labels, :comments, :conflicting_label, :failures
    attr_reader :calls

    def initialize
      @resource = { 'state' => 'open', 'title' => 'Current title', 'body' => 'Current body',
                    'user' => { 'type' => 'User', 'login' => 'contributor' } }
      @repository_labels = DEFINITIONS.map { |entry| entry.fetch('label') } + ['triage']
      @labels = %w[triage needs-more-info]
      @comments = []
      @failures = {}
      @calls = []
    end

    def request(method, path, payload = nil, paginate: false)
      @calls << { 'method' => method, 'path' => path, 'payload' => payload, 'paginate' => paginate }
      raise ContributionAutomation::APIError, failures[[method, path]] if failures.key?([method, path])

      result = case [method, path]
               when ['GET', ITEM], ['GET', "#{REPOSITORY}/pulls/153"]
                 resource
               when ['GET', "#{REPOSITORY}/labels?per_page=100"]
                 repository_labels.map { |name| { 'name' => name } }
               when ['GET', "#{ITEM}/labels?per_page=100"]
                 labels.map { |name| { 'name' => name } }
               when ['GET', "#{ITEM}/comments?per_page=100"]
                 comments
               when ['POST', "#{REPOSITORY}/labels"]
                 repository_labels << payload.fetch('name')
                 if conflicting_label == payload.fetch('name')
                   raise ContributionAutomation::APIError, 'Another run created this label (HTTP 422)'
                 end
                 payload
               when ['POST', "#{ITEM}/labels"]
                 @labels |= payload.fetch('labels')
                 labels.map { |name| { 'name' => name } }
               when ['POST', "#{ITEM}/comments"]
                 created = { 'id' => 1000 + comments.length, 'body' => payload.fetch('body'),
                             'user' => { 'login' => 'github-actions[bot]' } }
                 comments << created
                 created
               else
                 if method == 'GET' && path.start_with?("#{REPOSITORY}/labels/")
                   name = URI.decode_www_form_component(path.split('/').last)
                   raise ContributionAutomation::APIError, 'Not Found (HTTP 404)' unless repository_labels.include?(name)

                   { 'name' => name }
                 elsif method == 'DELETE' && path.start_with?("#{ITEM}/labels/")
                   labels.delete(URI.decode_www_form_component(path.split('/').last))
                   nil
                 elsif method == 'PATCH' && path.start_with?("#{REPOSITORY}/issues/comments/")
                   comments.find { |comment| comment.fetch('id') == path.split('/').last.to_i }['body'] = payload.fetch('body')
                 else
                   raise "Unexpected API call #{method} #{path}"
                 end
               end
      result = result.empty? ? [[]] : result.each_slice(2).to_a if paginate
      JSON.parse(JSON.generate(result))
    end
  end

  def setup
    @api = GitHubFixture.new
    @metadata = MetadataFixture.new
    @env = { 'GITHUB_REPOSITORY' => 'fixture/repository', 'CONTRIBUTION_NUMBER' => '153',
             'GITHUB_ACTOR' => 'contributor', 'GITHUB_DEFAULT_BRANCH' => 'main' }
  end

  def test_repeated_events_use_one_comment_and_do_not_write_unchanged_content
    assert_equal 'created', run_automation.fetch('comment')
    count = writes.length

    assert_equal 'unchanged', run_automation.fetch('comment')
    assert_equal count, writes.length
    assert_equal 1, @api.comments.length
    assert_includes @api.comments.first.fetch('body'), 'Steps to reproduce is required.'
    assert_includes @api.comments.first.fetch('body'), '/blob/main/CONTRIBUTING.md'
    assert_includes @api.comments.first.fetch('body'), '/blob/main/CONTRIBUTING.zh-CN.md'
  end

  def test_fixing_the_form_updates_feedback_and_removes_only_stale_contract_labels
    run_automation
    first_id = @api.comments.first.fetch('id')
    @api.labels.concat(['help wanted', 'skip-ci'])
    @metadata.metadata.merge!('valid' => true, 'errors' => [], 'labels' => %w[bug area:ci-build])

    assert_equal 'updated', run_automation.fetch('comment')
    assert_equal first_id, @api.comments.first.fetch('id')
    assert_equal ['triage', 'bug', 'area:ci-build', 'help wanted', 'skip-ci'], @api.labels
    assert_includes @api.comments.first.fetch('body'), 'pass the format check'
    refute_includes @api.comments.first.fetch('body'), 'Steps to reproduce is required.'
    assert_equal 1, writes.count { |call| call['method'] == 'PATCH' }
    assert_equal "#{ITEM}/labels/needs-more-info", writes.find { |call| call['method'] == 'DELETE' }.fetch('path')
  end

  def test_valid_first_contribution_gets_a_brief_welcome
    @metadata.metadata.merge!('valid' => true, 'errors' => [], 'labels' => ['bug'])
    run_automation

    assert_equal 1, @api.comments.length
    assert_includes @api.comments.first.fetch('body'), 'Thanks for contributing'
    assert_includes @api.comments.first.fetch('body'), 'pass the format check'
  end

  def test_marker_requires_the_exact_actions_bot_author_and_start_of_comment
    @api.comments = [comment(1, MARKER, 'contributor'), comment(2, MARKER, 'other[bot]'),
                     comment(3, "Quoted #{MARKER}"), comment(4, " #{MARKER}"), comment(5, nil)]
    preserved = JSON.parse(JSON.generate(@api.comments))
    run_automation

    assert_equal preserved, @api.comments.first(5)
    assert_equal 6, @api.comments.length
    assert_empty writes.select { |call| call['method'] == 'PATCH' }
  end

  def test_owned_comment_on_later_page_is_updated_in_place
    @api.comments = [comment(1, 'An unrelated comment'), comment(2, MARKER, 'contributor'), comment(3, MARKER)]
    run_automation

    assert_equal 3, @api.comments.length
    assert_equal "#{REPOSITORY}/issues/comments/3", writes.last.fetch('path')
    assert @api.calls.find { |call| call['path'].include?('/comments?') }.fetch('paginate')
  end

  def test_bot_authors_or_bot_events_sync_labels_without_welcome_comments
    [
      [{ 'type' => 'Bot', 'login' => 'automation' }, 'contributor'],
      [{ 'type' => 'User', 'login' => 'dependabot[bot]' }, 'contributor'],
      [{ 'type' => 'User', 'login' => 'contributor' }, 'github-actions[bot]']
    ].each do |user, actor|
      @api = GitHubFixture.new
      @api.resource['user'] = user
      @env['GITHUB_ACTOR'] = actor

      assert_equal 'skipped-bot', run_automation.fetch('comment')
      assert_includes @api.labels, 'bug'
      assert_empty @api.comments
      refute @api.calls.any? { |call| call['path'].include?('/comments') }
    end
  end

  def test_dependabot_pull_requests_preserve_labels_without_metadata_or_feedback
    @api.resource['user'] = { 'type' => 'Bot', 'login' => 'dependabot[bot]' }
    @api.labels = %w[dependencies github_actions skip-ci triage]

    assert_equal({ 'skipped' => 'dependabot' }, run_automation('pr'))
    assert_equal %w[dependencies github_actions skip-ci triage], @api.labels
    assert_empty @metadata.resources
    assert_empty @api.comments
    assert_empty writes
    assert_equal ["#{REPOSITORY}/pulls/153", "#{ITEM}/labels?per_page=100"], @api.calls.map { |call| call.fetch('path') }
  end

  def test_dependabot_pull_requests_remove_only_existing_format_feedback_labels
    @api.resource['user'] = { 'type' => 'Bot', 'login' => 'dependabot[bot]' }
    @api.labels = %w[dependencies Needs-More-Info triage skip-ci]

    assert_equal({ 'skipped' => 'dependabot' }, run_automation('pr'))
    assert_equal %w[dependencies triage skip-ci], @api.labels
    assert_empty @metadata.resources
    assert_empty @api.comments
    assert_equal [['DELETE', "#{ITEM}/labels/Needs-More-Info"]], writes.map { |call| call.values_at('method', 'path') }
  end

  def test_dependabot_exception_requires_exact_pr_author_identity
    [
      ['pr', { 'type' => 'User', 'login' => 'dependabot[bot]' }, 'contributor'],
      ['pr', { 'type' => 'Bot', 'login' => 'renovate[bot]' }, 'contributor'],
      ['pr', { 'type' => 'User', 'login' => 'contributor' }, 'dependabot[bot]'],
      ['issue', { 'type' => 'Bot', 'login' => 'dependabot[bot]' }, 'contributor']
    ].each do |kind, user, actor|
      @api = GitHubFixture.new
      @metadata = MetadataFixture.new
      @api.resource['user'] = user
      @env['GITHUB_ACTOR'] = actor

      result = run_automation(kind)
      refute result.key?('skipped')
      assert_equal 1, @metadata.resources.length
      assert_equal 'skipped-bot', result.fetch('comment')
      assert_includes @api.labels, 'needs-more-info'
    end
  end

  def test_missing_labels_are_created_with_contract_properties
    @api.repository_labels -= ['area:ci-build']
    run_automation

    creation = writes.find { |call| call['path'] == "#{REPOSITORY}/labels" }
    assert_equal({ 'name' => 'area:ci-build', 'color' => 'd73a4a', 'description' => 'Contract label area:ci-build' }, creation.fetch('payload'))
    assert_includes @api.labels, 'area:ci-build'
  end

  def test_label_matching_respects_github_case_insensitivity
    @api.repository_labels = %w[Bug AREA:CI-BUILD Needs-More-Info triage]
    @api.labels = %w[Bug AREA:CI-BUILD Needs-More-Info triage]
    @metadata.metadata.merge!('valid' => true, 'errors' => [], 'labels' => %w[bug area:ci-build])
    run_automation

    assert_equal %w[Bug AREA:CI-BUILD triage], @api.labels
    assert_empty writes.select { |call| call['method'] == 'POST' && call['path'].end_with?('/labels') }
  end

  def test_label_creation_race_rechecks_the_label_before_continuing
    @api.repository_labels -= ['area:ci-build']
    @api.conflicting_label = 'area:ci-build'

    assert_equal 'created', run_automation.fetch('comment')
    assert @api.calls.any? { |call| call['method'] == 'GET' && call['path'] == "#{REPOSITORY}/labels/area%3Aci-build" }
    assert_equal 1, @api.repository_labels.count('area:ci-build')
  end

  def test_label_creation_failure_is_not_hidden_if_the_label_still_does_not_exist
    @api.repository_labels -= ['area:ci-build']
    @api.failures[['POST', "#{REPOSITORY}/labels"]] = 'Forbidden (HTTP 403)'

    error = assert_raises(ContributionAutomation::APIError) { run_automation }
    assert_includes error.message, 'Forbidden'
    assert_equal %w[triage needs-more-info], @api.labels
    assert_empty @api.comments
  end

  def test_failed_metadata_or_comment_reads_do_not_write
    [ITEM, "#{ITEM}/comments?per_page=100"].each do |path|
      @api = GitHubFixture.new
      @api.failures[['GET', path]] = 'Unavailable (HTTP 503)'

      assert_raises(ContributionAutomation::APIError) { run_automation }
      assert_empty writes
    end
  end

  def test_comment_write_failures_are_reported
    [[], [comment(3, MARKER)]].each do |comments|
      @api = GitHubFixture.new
      @api.comments = comments
      method, path = comments.empty? ? ['POST', "#{ITEM}/comments"] : ['PATCH', "#{REPOSITORY}/issues/comments/3"]
      @api.failures[[method, path]] = 'Forbidden (HTTP 403)'

      assert_raises(ContributionAutomation::APIError) { run_automation }
    end
  end

  def test_only_current_resource_content_is_parsed_and_the_body_is_never_rewritten
    @env.merge!('ISSUE_TITLE' => 'Stale title', 'ISSUE_BODY' => 'Stale body')
    original = JSON.parse(JSON.generate(@api.resource))
    run_automation

    assert_equal [original], @metadata.resources
    assert_equal original, @api.resource
    assert_equal ['GET', ITEM], @api.calls.first.values_at('method', 'path')
    refute writes.any? { |call| call['path'] == ITEM || call['path'].include?('/pulls/') || call['path'].include?('projects') }
  end

  def test_pull_request_uses_current_metadata_and_has_its_own_comment_marker
    @metadata.metadata.merge!('valid' => true, 'errors' => [])
    @api.resource['head'] = { 'ref' => 'untrusted-head', 'sha' => 'untrusted-sha', 'repo' => { 'full_name' => 'fork/repository' } }
    run_automation('pr')

    assert_equal ['GET', "#{REPOSITORY}/pulls/153"], @api.calls.first.values_at('method', 'path')
    assert_includes @api.comments.first.fetch('body'), '<!-- another-you-pr-automation -->'
    assert_includes @api.comments.first.fetch('body'), 'CI results and code review are tracked separately.'
    refute @api.calls.any? { |call| call['path'].include?('untrusted') || call['path'].include?('fork/repository') }
  end

  def test_stale_open_event_for_a_now_closed_item_does_not_write
    @api.resource['state'] = 'closed'
    assert_equal({ 'skipped' => 'closed' }, run_automation)
    assert_equal 1, @api.calls.length
    assert_empty @metadata.resources
    assert_empty writes
  end

  def test_bad_identifiers_and_undeclared_labels_fail_before_mutation
    ['', '0', '-1', '1.5', '../153', '153;echo unsafe', "153\n154"].each do |number|
      assert_raises(ContributionAutomation::Error) { run_automation('issue', 'CONTRIBUTION_NUMBER' => number) }
      assert_empty @api.calls
    end
    ['repository', 'owner/repo/extra', 'owner/..', '$(whoami)/repo'].each do |repository|
      assert_raises(ContributionAutomation::Error) { run_automation('issue', 'GITHUB_REPOSITORY' => repository) }
      assert_empty @api.calls
    end
    assert_raises(ContributionAutomation::Error) { run_automation('discussion') }
    @metadata.metadata['labels'] << 'manual-label'
    assert_raises(ContributionAutomation::Error) { run_automation }
    assert_empty writes
  end

  def test_real_metadata_readers_treat_shell_text_as_data_and_clean_temporary_files
    Dir.mktmpdir('another-you-automation-reader-test-') do |directory|
      canary = File.join(directory, 'should-not-exist')
      resource = @api.resource.merge('title' => "$(touch #{canary})", 'body' => "`touch #{canary}`\n${{ github.token }}")
      %w[issue pr].each do |kind|
        metadata, definitions = ContributionAutomation::MetadataReader.new(kind, directory).read(resource)
        refute metadata.fetch('valid')
        assert_includes metadata.fetch('labels'), 'needs-more-info'
        assert definitions.any? { |entry| entry.fetch('label') == 'needs-more-info' }
        assert_empty Dir.children(directory)
      end
      assert_raises(ContributionAutomation::Error) do
        ContributionAutomation::MetadataReader.new('missing', directory).read(resource)
      end
      assert_empty Dir.children(directory)
    end
  end

  def test_actual_issue_and_pr_contracts_recover_from_missing_fields
    cases = [
      ['issue', '[Feature] Include source build requirements', <<~BODY, %w[enhancement area:docs]],
        ### Area
        Documentation

        ### Problem to solve
        The installation guide omits source build requirements.

        ### Proposed solution
        Add the required Node and Swift versions to the source build checklist.

        ### Pre-submission checks
        - [x] I searched existing Issues and confirmed that this is not a duplicate.
      BODY
      ['pr', 'docs: include source build requirements', <<~BODY, %w[documentation development]]
        ## Summary
        Document the source build requirements before running the application.

        ## PR Type
        - Type: docs

        ## Validation
        - Status: passed
        - Command: make check-ci
        - Result: Repository metadata checks passed in the fixture.

        ## Risk and Rollback
        - Risk: Documentation-only changes do not affect runtime behavior.
        - Rollback: Revert the documentation change.

        ## Related Issue
        Closes #42
      BODY
    ]
    cases.each do |kind, title, body, labels|
      Dir.mktmpdir('another-you-automation-contract-test-') do |directory|
        @api = GitHubFixture.new
        @api.labels << 'skip-ci'
        @metadata = ContributionAutomation::MetadataReader.new(kind, directory)
        refute run_automation(kind).fetch('valid')
        @api.resource.merge!('title' => title, 'body' => body)

        result = run_automation(kind)
        assert result.fetch('valid'), @api.comments.first.fetch('body')
        assert_equal 'updated', result.fetch('comment')
        assert_equal 1, @api.comments.length
        assert_equal (labels + %w[triage skip-ci]).sort, @api.labels.sort
        assert_empty Dir.children(directory)
      end
    end
  end

  def test_gh_api_uses_argument_arrays_and_json_stdin_instead_of_shell_interpolation
    captured = nil
    body = "$(exit 77) `exit 77` ' \" \n${{ github.token }}"
    with_gh_fixture(output: '{}') do |capture|
      ContributionAutomation::GitHub.new.request('POST', "#{ITEM}/comments", { 'body' => body })
      captured = JSON.parse(File.read(capture))
    end

    assert_equal ['api', '--method', 'POST', "#{ITEM}/comments", '--input', '-'], captured.fetch('arguments')
    assert_equal({ 'body' => body }, JSON.parse(captured.fetch('input')))
  end

  def test_gh_api_rejects_invalid_json_and_propagates_read_failures
    with_gh_fixture(output: 'not json') do
      assert_raises(JSON::ParserError) { ContributionAutomation::GitHub.new.list("#{ITEM}/comments") }
    end
    with_gh_fixture(output: '{}') do
      assert_raises(ContributionAutomation::Error) { ContributionAutomation::GitHub.new.list("#{ITEM}/comments") }
    end
    with_gh_fixture(output: '', diagnostic: 'Forbidden (HTTP 403)', status: 1) do
      assert_raises(ContributionAutomation::APIError) { ContributionAutomation::GitHub.new.list("#{ITEM}/comments") }
    end
  end

  def test_gh_api_flattens_all_comment_pages
    pages = [[comment(1, 'First page')], [comment(2, MARKER)]]
    with_gh_fixture(output: JSON.generate(pages)) do |capture|
      assert_equal pages.flatten(1), ContributionAutomation::GitHub.new.list("#{ITEM}/comments")
      arguments = JSON.parse(File.read(capture)).fetch('arguments')
      assert_includes arguments, '--paginate'
      assert_includes arguments, '--slurp'
    end
  end

  def test_workflows_keep_fork_content_outside_the_write_token_trust_boundary
    { 'issue' => ['issues', %w[opened edited reopened]],
      'pr' => ['pull_request_target', %w[opened edited reopened synchronize ready_for_review]] }.each do |kind, (trigger, events)|
      workflow = YAML.load_file(File.join(ROOT, '.github/workflows', "#{kind}-automation.yml"))
      triggers = workflow['on'] || workflow.fetch(true)
      assert_equal [trigger], triggers.keys
      assert_equal events, triggers.fetch(trigger).fetch('types')
      assert_equal({ 'contents' => 'read' }, workflow.fetch('permissions'))
      assert_equal false, workflow.fetch('concurrency').fetch('cancel-in-progress')
      assert_includes workflow.fetch('concurrency').fetch('group'), '.number'
      job = workflow.fetch('jobs').fetch('automate')
      permissions = { 'contents' => 'read', 'issues' => 'write' }
      permissions['pull-requests'] = 'write' if kind == 'pr'
      assert_equal permissions, job.fetch('permissions')
      steps = job.fetch('steps')
      assert_equal 2, steps.length
      assert_match(/\Aactions\/checkout@[a-f0-9]{40}\z/, steps.first.fetch('uses'))
      assert_equal({ 'ref' => '${{ github.event.repository.default_branch }}', 'persist-credentials' => false }, steps.first.fetch('with'))
      assert_equal "ruby .github/scripts/contribution-automation.rb #{kind}", steps.last.fetch('run')
      refute_includes steps.last.fetch('run'), '${{'
      assert_equal '${{ github.token }}', steps.last.fetch('env').fetch('GH_TOKEN')
      refute job.key?('if'), 'Fork contributions must not be excluded.'
      refute steps.last.fetch('env').values.any? { |value| value.include?('.head') || value.include?('.body') || value.include?('.title') }
    end
  end

  private

  def run_automation(kind = 'issue', overrides = {})
    ContributionAutomation::Runner.new(kind, env: @env.merge(overrides), api: @api, metadata_reader: @metadata).run
  end

  def writes
    @api.calls.reject { |call| call['method'] == 'GET' }
  end

  def comment(id, body, login = 'github-actions[bot]')
    { 'id' => id, 'body' => body, 'user' => { 'login' => login } }
  end

  def with_gh_fixture(output:, diagnostic: '', status: 0)
    original_path = ENV.fetch('PATH')
    Dir.mktmpdir('another-you-automation-gh-test-') do |directory|
      script = File.join(directory, 'gh')
      File.write(script, <<~'RUBY')
        #!/usr/bin/env ruby
        require 'json'
        File.write(File.join(__dir__, 'capture.json'), JSON.generate(arguments: ARGV, input: STDIN.read))
        response = JSON.parse(File.read(File.join(__dir__, 'response.json')))
        STDOUT.write(response.fetch('output'))
        STDERR.write(response.fetch('diagnostic'))
        exit response.fetch('status')
      RUBY
      File.chmod(0o755, script)
      File.write(File.join(directory, 'response.json'), JSON.generate(output: output, diagnostic: diagnostic, status: status))
      ENV['PATH'] = "#{directory}:#{original_path}"
      yield File.join(directory, 'capture.json')
    end
  ensure
    ENV['PATH'] = original_path
  end
end
