#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'rbconfig'
require_relative 'ci-skip-directives'

class CISkipDirectivesTest < Minitest::Test
  HEAD = 'a' * 40
  SCRIPT = File.join(__dir__, 'ci-skip-directives.rb')

  class FixtureAPI
    attr_accessor :pr, :comments, :runs, :candidates, :permissions, :complete_cancellation, :head_after_cancel, :repository_labels, :label_created_concurrently, :fail_initial_summary, :fail_summary_after_rerun, :fail_label_write
    attr_reader :calls

    def initialize
      @calls = []
      @permissions = { 'maintainer' => 'write' }
      @comments, @runs, @candidates = [], [], []
      @complete_cancellation = true
      @repository_labels = [{ 'name' => 'skip-ci' }]
    end

    def pages(path, key = nil)
      @calls << ['GET pages', path, key]
      return copy(@comments) if path.end_with?('/comments')
      return copy(@candidates) if path.include?('/pulls?')
      return copy(@runs) if path.include?('/actions/runs?')
      return copy(@repository_labels) if path.end_with?('/labels')

      raise "未预期分页：#{path}"
    end

    def request(method, path, body = nil)
      @calls << [method, path, body]
      return copy(@pr) if method == 'GET' && path.end_with?('/pulls/7')
      if method == 'GET' && path.include?('/collaborators/')
        return { 'permission' => @permissions.fetch(path.split('/')[-2], 'read') }
      end
      match = %r{/actions/runs/(\d+)(?:/(cancel|rerun))?\z}.match(path)
      if match
        run = @runs.find { |item| item.fetch('id') == match[1].to_i }
        raise '未找到 run' unless run
        return copy(run) if method == 'GET'

        if match[2] == 'cancel'
          run['status'] = 'completed' if @complete_cancellation
          @pr['head']['sha'] = @head_after_cancel if @head_after_cancel
        else
          run['status'] = 'queued'
        end
        return nil
      end
      if method == 'POST' && path.end_with?('/comments')
        raise 'summary create failed' if @fail_initial_summary

        comment = { 'id' => 900 + @comments.length, 'body' => body.fetch('body'), 'user' => { 'login' => 'github-actions[bot]', 'type' => 'Bot' }, 'created_at' => '2026-10-08T10:00:00Z', 'updated_at' => '2026-10-08T10:00:00Z' }
        @comments << comment
        return copy(comment)
      end
      if method == 'PATCH' && path.include?('/issues/comments/')
        raise 'summary update failed after rerun' if @fail_summary_after_rerun && @calls.any? { |verb, endpoint| verb == 'POST' && endpoint.end_with?('/rerun') }

        @comments.find { |item| item.fetch('id') == path.split('/').last.to_i }['body'] = body.fetch('body')
        return nil
      end
      if method == 'POST' && path.end_with?('/issues/7/labels')
        raise 'label write failed' if @fail_label_write

        @pr['labels'] << { 'name' => 'skip-ci' }
        return nil
      end
      if method == 'POST' && path.end_with?('/labels')
        @repository_labels << { 'name' => 'Skip-CI' } if @label_created_concurrently
        raise 'HTTP 422 label already exists'
      end
      if method == 'DELETE' && path.downcase.end_with?('/labels/skip-ci')
        @pr['labels'].reject! { |label| label['name'].casecmp?('skip-ci') }
        return nil
      end
      raise "未预期 API：#{method} #{path}"
    end

    def copy(value)
      Marshal.load(Marshal.dump(value))
    end
  end

  def setup
    @manifest = CISkip::Manifest.new(JSON.parse(File.read(File.expand_path('../ci-skip.json', __dir__))))
    @api = FixtureAPI.new
    @api.pr = { 'number' => 7, 'state' => 'open', 'created_at' => '2026-10-08T07:00:00Z', 'closed_at' => nil, 'labels' => [], 'head' => { 'sha' => HEAD, 'ref' => 'fix/example', 'repo' => { 'id' => 101, 'full_name' => 'contributor/another-you', 'owner' => { 'login' => 'contributor' } } } }
    @api.runs = [fixture_run]
    @api.candidates = [@api.copy(@api.pr)]
    @controller = controller
  end

  def test_workflow_names_and_job_aliases
    { 'ci' => %w[agent swift website], 'SwiftUI macOS' => ['swift'], 'xcode' => ['swift'], 'Website and scripts' => ['website'], 'CI Lint' => ['lint'], 'actionlint' => ['lint'], 'CodeQL' => ['codeql'], 'Dependency Review' => ['deps'], 'skills' => ['skills'], 'pr-quality-gates' => ['quality'], 'all' => @manifest.ids }.each do |value, expected|
      assert_equal expected, @manifest.resolve_alias(value), value
    end
    assert_nil @manifest.resolve_alias('unknown target')
    assert_equal %w[agent swift website], @manifest.resolve_alias('ci.yml')
    assert_equal ['lint'], @manifest.resolve_alias('ci-lint.yml')
  end

  def test_standalone_commands_and_reasons
    commands = CISkip.directives("skip-swift: SDK unavailable\nunskip-web reason\nSkip-CI Lint! maintenance")
    assert_equal [true, false, true], commands.map { |item| item['skip'] }
    assert_equal %w[swift], @manifest.resolve_alias(commands[0]['target'])
    assert_equal ['website'], @manifest.resolve_alias(commands[1]['target'])
    assert_equal ['lint'], @manifest.resolve_alias(commands[2]['target'])
  end

  def test_quoted_fenced_indented_inline_and_html_examples_do_not_execute
    ["> skip-all", 'Please use skip-all', '`skip-all`', "    skip-all", "\tskip-all", "```markdown\nskip-all\n```", "~~~\nskip-all\n~~~", "```markdown\n~~~\nskip-all\n```", "````\n```\nskip-all\n````", "```\n``` example\nskip-all\n```", "<!-- skip-all -->", "<!--\nskip-all"].each do |body|
      assert_empty CISkip.directives(body), body
    end
    assert_equal 1, CISkip.directives("```\nskip-all\n```\nskip-swift").length
  end

  def test_only_live_write_maintain_or_admin_is_authorized
    %w[read triage none].each do |permission|
      assert_empty resolve([comment('skip-all')], permission: permission)['targets']
    end
    %w[write maintain admin].each do |permission|
      assert_equal @manifest.ids, resolve([comment('skip-all')], permission: permission)['targets']
    end
    bot = comment('skip-all')
    bot['user']['type'] = 'Bot'
    assert_empty resolve([bot])['targets']
  end

  def test_server_time_rejects_old_missing_and_same_second_comments
    ['2026-10-08T07:59:59Z', '2026-10-08T08:00:00Z', nil, 'invalid'].each do |time|
      item = comment('skip-all')
      item['updated_at'] = time
      assert_empty resolve([item])['targets']
    end
    assert_empty CISkip.resolve(@manifest, [comment('skip-all')], { 'maintainer' => 'write' }, nil)['targets']
  end

  def test_latest_edits_and_line_order_restore_selected_targets
    older = comment('skip-all', id: 1)
    newer = comment("unskip-all\nskip-swift\nskip-website\nunskip-web", id: 2, at: '2026-10-08T09:01:00Z')
    assert_equal ['swift'], resolve([newer, older])['targets']
    older['updated_at'] = '2026-10-08T09:02:00Z'
    assert_equal @manifest.ids, resolve([newer, older])['targets']
  end

  def test_partial_skip_only_skips_its_target
    @api.comments = [comment('skip-swift')]
    @controller.apply
    decision = @controller.gate('CI', HEAD)
    assert_equal false, decision['skip']
    assert_equal ['swift'], decision['targets']
    @api.comments = [comment('skip-ci')]
    @controller.apply
    assert @controller.gate('CI', HEAD)['skip']
  end

  def test_stale_run_head_never_uses_current_head_directives
    @api.comments = [comment('skip-all')]
    result = @controller.gate('CI', 'b' * 40)
    assert_equal false, result['skip']
    assert_empty result['targets']
  end

  def test_partial_skip_cancels_then_reruns_only_affected_workflow_without_fake_success
    @api.comments = [comment('skip-swift')]
    @api.runs << fixture_run(id: 43, file: 'codeql.yml')
    @controller.apply
    assert_equal [42], action_ids('cancel')
    assert_equal [42], action_ids('rerun')
    refute @api.calls.any? { |_, path| path.include?('check-runs') || path.include?('statuses') }
    assert_equal 1, managed_comments.length
    assert @api.pr['labels'].any? { |label| label['name'] == 'skip-ci' }
    assert_operator call_index('/42/cancel'), :<, call_index('/42/rerun')
  end

  def test_repeated_decision_and_unrelated_comments_do_not_rerun
    @api.comments = [comment('skip-swift')]
    @controller.apply
    @controller.apply
    @api.comments << comment('Thank you', id: 2)
    @controller.apply
    assert_equal [42], action_ids('rerun')
    assert_equal 1, managed_comments.length
  end

  def test_unskip_reruns_real_checks_and_preserves_unrelated_labels
    @api.pr['labels'] = [{ 'name' => 'bug' }]
    @api.comments = [comment('skip-swift')]
    @controller.apply
    @api.comments << comment('unskip-all', id: 2, at: '2026-10-08T11:00:00Z')
    @controller.apply
    assert_equal [42, 42], action_ids('rerun')
    assert_equal [{ 'name' => 'bug' }], @api.pr['labels']
    assert_includes managed_comments.first['body'], 'No skip directive is active.'
  end

  def test_label_creation_race_is_rechecked_case_insensitively
    @api.comments = [comment('skip-swift')]
    @api.repository_labels = []
    @api.label_created_concurrently = true
    @controller.apply
    assert_equal [42], action_ids('rerun')
    assert_equal 1, managed_comments.length
    assert @api.pr['labels'].any? { |label| label['name'] == 'skip-ci' }
    @controller.apply
    assert_equal [42], action_ids('rerun')
  end

  def test_case_variant_skip_label_is_removed_without_touching_other_labels
    @api.comments = [comment('skip-swift')]
    @controller.apply
    @api.pr['labels'] = [{ 'name' => 'Skip-CI' }, { 'name' => 'bug' }]
    @api.comments << comment('unskip-all', id: 2, at: '2026-10-08T11:00:00Z')
    @controller.apply
    assert_equal [{ 'name' => 'bug' }], @api.pr['labels']
  end

  def test_deleting_or_editing_the_last_directive_restores_checks
    [false, true].each do |edit|
      setup
      @api.comments = [comment('skip-swift')]
      @controller.apply
      edit ? @api.comments.first['body'] = 'No directive remains' : @api.comments.shift
      @controller.apply
      assert_equal [42, 42], action_ids('rerun'), "edit=#{edit}"
      refute @api.pr['labels'].any? { |label| label['name'] == 'skip-ci' }
    end
  end

  def test_new_head_expires_old_directives_without_cancelling_the_new_run
    @api.comments = [comment('skip-swift')]
    @controller.apply
    @api.pr['head']['sha'] = 'b' * 40
    @api.runs = [fixture_run(id: 44).merge('head_sha' => 'b' * 40, 'created_at' => '2026-10-08T11:00:00Z')]
    @api.candidates = [@api.copy(@api.pr)]
    @controller.apply
    assert_equal [42], action_ids('cancel')
    assert_equal [42], action_ids('rerun')
    assert_empty @api.pr['labels']
    assert_includes managed_comments.first['body'], 'b' * 40
  end

  def test_old_head_runs_are_not_rerun_when_current_workflow_is_absent
    @api.comments = [comment('skip-swift')]
    @api.runs = [fixture_run.merge('head_sha' => 'b' * 40), fixture_run(id: 43, file: 'codeql.yml')]
    @controller.apply
    assert_empty action_ids('cancel')
    assert_empty action_ids('rerun')
  end

  def test_live_permission_revocation_removes_effective_skip
    @api.comments = [comment('skip-swift')]
    @controller.apply
    @api.permissions['maintainer'] = 'read'
    assert_empty @controller.gate('CI', HEAD)['targets']
    @controller.apply
    assert_equal [42, 42], action_ids('rerun')
  end

  def test_head_change_after_cancel_stops_before_rerun
    @api.comments = [comment('skip-swift')]
    @api.head_after_cancel = 'b' * 40
    assert_raises(RuntimeError) { @controller.apply }
    assert_equal [42], action_ids('cancel')
    assert_empty action_ids('rerun')
    assert_equal 'pending', receipt.fetch('status')
    assert_equal HEAD, receipt.fetch('head')
  end

  def test_async_cancel_timeout_does_not_rerun_or_report_success
    @api.comments = [comment('skip-swift')]
    @api.complete_cancellation = false
    ticks = [-1, 301]
    timed = controller(clock: -> { ticks.shift || 301 })
    error = assert_raises(RuntimeError) { timed.apply }
    assert_includes error.message, '超时'
    assert_empty action_ids('rerun')
    assert_equal 'pending', receipt.fetch('status')
    assert_equal ['ci.yml'], receipt.fetch('pending')
  end

  def test_initial_receipt_failure_cannot_skip_or_restart_any_check
    @api.comments = [comment('skip-swift')]
    @api.fail_initial_summary = true
    assert_raises(RuntimeError) { @controller.apply }
    assert_empty action_ids('cancel')
    assert_empty action_ids('rerun')
    assert_empty @controller.gate('CI', HEAD).fetch('targets')
  end

  def test_pending_receipt_survives_rerun_success_and_summary_failure_then_deleted_directive
    @api.comments = [comment('skip-swift')]
    @api.fail_summary_after_rerun = true
    assert_raises(RuntimeError) { @controller.apply }
    assert_equal [42], action_ids('rerun')
    assert_equal 'pending', receipt.fetch('status')
    assert_equal ['swift'], @controller.gate('CI', HEAD).fetch('targets')
    @api.comments.shift
    @api.fail_summary_after_rerun = false
    @controller.apply
    assert_equal [42, 42], action_ids('rerun')
    assert_empty receipt.fetch('targets')
    assert_equal 'applied', receipt.fetch('status')
  end

  def test_applied_receipt_survives_label_failure_and_restores_after_comment_deletion
    @api.comments = [comment('skip-swift')]
    @api.fail_label_write = true
    assert_raises(RuntimeError) { @controller.apply }
    assert_equal 'applied', receipt.fetch('status')
    @api.comments.shift
    @api.fail_label_write = false
    @controller.apply
    assert_equal [42, 42], action_ids('rerun')
    assert_empty receipt.fetch('targets')
  end

  def test_unskip_recovers_when_receipt_is_deleted_but_managed_label_remains
    @api.comments = [comment('skip-swift')]
    @controller.apply
    @api.comments.reject! { |item| item.dig('user', 'type') == 'Bot' }
    @api.comments << comment('unskip-all', id: 2, at: '2026-10-08T11:00:00Z')
    @controller.apply
    assert_equal [42, 42], action_ids('rerun')
    assert_empty @api.pr['labels']
  end

  def test_deleted_receipt_event_can_recover_even_without_a_label_or_human_comment
    @api.comments = [comment('skip-swift')]
    @api.fail_label_write = true
    assert_raises(RuntimeError) { @controller.apply }
    deleted = managed_comments.first.fetch('body')
    @api.comments = []
    @api.fail_label_write = false
    @controller.apply(deleted_summary: deleted)
    assert_equal [42, 42], action_ids('rerun')
    assert_empty receipt.fetch('targets')
  end

  def test_pending_retry_is_resumable_and_applied_retry_is_idempotent
    @api.comments = [comment('skip-swift')]
    @api.fail_summary_after_rerun = true
    assert_raises(RuntimeError) { @controller.apply }
    @api.fail_summary_after_rerun = false
    @controller.apply
    assert_equal 'applied', receipt.fetch('status')
    assert_equal [42, 42], action_ids('rerun')
    @controller.apply
    assert_equal [42, 42], action_ids('rerun')
  end

  def test_quoted_marker_is_not_a_managed_receipt
    @api.comments = [comment('skip-swift')]
    @controller.apply
    managed_comments.first['body'] = "Quoted example:\n#{managed_comments.first.fetch('body')}"
    assert_empty @controller.gate('CI', HEAD).fetch('targets')
    @api.comments.shift
    @api.pr['labels'] = []
    before = @api.calls.length
    @controller.apply
    assert_empty @api.calls.drop(before).reject { |method, _| method.start_with?('GET') }
  end

  def test_closed_pull_request_with_receipt_and_label_is_a_no_op
    @api.comments = [comment('skip-swift')]
    @controller.apply
    @api.pr['state'] = 'closed'
    before = @api.calls.length
    @controller.apply
    assert_empty @api.calls.drop(before).reject { |method, _| method.start_with?('GET') }
    assert_empty @controller.gate('CI', HEAD).fetch('targets')
    assert_equal [42], action_ids('rerun')
  end

  def test_fork_identity_and_explicit_pr_routing
    assert @controller.matching_run?(fixture_run, @api.pr, @api.candidates)
    [{ 'event' => 'push' }, { 'head_sha' => 'b' * 40 }, { 'head_branch' => 'other' }, { 'path' => '.github/workflows/unmanaged.yml' }, { 'pull_requests' => [{ 'number' => 8 }] }, { 'pull_requests' => [{ 'number' => 7 }, { 'number' => 8 }] }, { 'head_repository' => { 'id' => 999, 'full_name' => 'other/fork' } }].each do |change|
      refute @controller.matching_run?(fixture_run.merge(change), @api.pr, @api.candidates), change.inspect
    end
  end

  def test_empty_pull_requests_actual_api_shape_requires_unique_live_pr
    empty = fixture_run.merge('pull_requests' => [])
    assert @controller.matching_run?(empty, @api.pr, @api.candidates)
    other = @api.copy(@api.pr).merge('number' => 8)
    refute @controller.matching_run?(empty, @api.pr, [@api.pr, other])
    other['closed_at'] = '2026-10-08T07:30:00Z'
    assert @controller.matching_run?(empty, @api.pr, [@api.pr, other])
    other['closed_at'] = '2026-10-08T08:30:00Z'
    refute @controller.matching_run?(empty, @api.pr, [@api.pr, other])
    refute @controller.matching_run?(empty.merge('created_at' => '2026-10-08T06:00:00Z'), @api.pr, [@api.pr])
  end

  def test_unknown_targets_and_unauthorized_comments_do_not_restart
    @api.comments = [comment('skip-unknown')]
    @controller.apply
    assert_empty action_ids('rerun')
    assert_includes managed_comments.first['body'], 'Unknown targets ignored: 1'
    setup
    @api.comments = [comment('skip-all')]
    @api.permissions['maintainer'] = 'read'
    @controller.apply
    assert_empty managed_comments
    assert_empty action_ids('rerun')
  end

  def test_comment_pagination_reads_beyond_first_hundred
    api = Class.new(CISkip::API) do
      attr_reader :pages_seen
      def request(_method, path, _body = nil)
        @pages_seen ||= []
        page = path[/page=(\d+)\z/, 1].to_i
        @pages_seen << page
        Array.new(page < 3 ? 100 : 5) { |i| { 'id' => (page - 1) * 100 + i } }
      end
    end.new
    assert_equal 205, api.pages('repos/owner/repo/issues/7/comments').length
    assert_equal [1, 2, 3], api.pages_seen
  end

  def test_real_cli_gate_fails_open_when_github_api_is_unavailable
    Dir.mktmpdir('another-you-skip-cli-') do |directory|
      File.write(File.join(directory, 'gh'), "#!/bin/sh\nexit 1\n")
      File.chmod(0o755, File.join(directory, 'gh'))
      output_file = File.join(directory, 'output')
      env = { 'PATH' => "#{directory}:#{ENV.fetch('PATH')}", 'GITHUB_REPOSITORY' => 'owner/repo', 'PR_NUMBER' => '7', 'WORKFLOW_NAME' => 'CI', 'EXPECTED_HEAD_SHA' => HEAD, 'GITHUB_OUTPUT' => output_file }
      output, status = Open3.capture2e(env, RbConfig.ruby, SCRIPT, 'gate')
      assert status.success?, output
      assert_equal "skip=false\ntargets=[]\nhead-sha=\n", File.read(output_file)
      assert_includes output, '正常执行所有检查'
    end
  end

  def test_real_api_client_keeps_comment_payload_as_json_data
    Dir.mktmpdir('another-you-skip-api-') do |directory|
      File.write(File.join(directory, 'gh'), <<~'RUBY')
        #!/usr/bin/env ruby
        require 'json'
        File.write(ENV.fetch('CI_SKIP_TEST_TRACE'), JSON.generate({ 'arguments' => ARGV, 'input' => STDIN.read }))
        puts JSON.generate({ 'id' => 1 })
      RUBY
      File.chmod(0o755, File.join(directory, 'gh'))
      old_path, old_trace = ENV.values_at('PATH', 'CI_SKIP_TEST_TRACE')
      begin
        ENV['PATH'] = "#{directory}:#{old_path}"
        ENV['CI_SKIP_TEST_TRACE'] = File.join(directory, 'trace.json')
        marker = File.join(directory, 'must-not-exist')
        payload = { 'body' => "skip-swift: $(touch #{marker}) `touch #{marker}`\n中文内容" }
        assert_equal({ 'id' => 1 }, CISkip::API.new.request('POST', 'repos/owner/repo/issues/7/comments', payload))
        trace = JSON.parse(File.read(ENV.fetch('CI_SKIP_TEST_TRACE')))
        assert_equal ['api', '--method', 'POST', 'repos/owner/repo/issues/7/comments', '--input', '-'], trace.fetch('arguments')
        assert_equal payload, JSON.parse(trace.fetch('input'))
        refute File.exist?(marker)
      ensure
        ENV['PATH'] = old_path
        old_trace.nil? ? ENV.delete('CI_SKIP_TEST_TRACE') : ENV['CI_SKIP_TEST_TRACE'] = old_trace
      end
    end
  end

  private

  def controller(clock: -> { 0 })
    CISkip::Controller.new(api: @api, manifest: @manifest, repository: 'owner/repo', number: '7', pause: -> {}, clock: clock)
  end

  def fixture_run(id: 42, file: 'ci.yml')
    { 'id' => id, 'event' => 'pull_request', 'head_sha' => HEAD, 'head_branch' => 'fix/example', 'head_repository' => { 'id' => 101, 'full_name' => 'contributor/another-you' }, 'path' => ".github/workflows/#{file}", 'pull_requests' => [{ 'number' => 7 }], 'created_at' => '2026-10-08T08:00:00Z', 'status' => 'in_progress' }
  end

  def comment(body, id: 1, at: '2026-10-08T09:00:00Z')
    { 'id' => id, 'body' => body, 'user' => { 'login' => 'maintainer', 'type' => 'User' }, 'author_association' => 'OWNER', 'created_at' => at, 'updated_at' => at }
  end

  def resolve(comments, permission: 'write')
    CISkip.resolve(@manifest, comments, { 'maintainer' => permission }, Time.iso8601('2026-10-08T08:00:00Z'))
  end

  def action_ids(action)
    @api.calls.filter_map { |method, path| path[%r{/runs/(\d+)/#{action}\z}, 1]&.to_i if method == 'POST' }
  end

  def call_index(suffix)
    @api.calls.index { |method, path| method == 'POST' && path.end_with?(suffix) }
  end

  def managed_comments
    @api.comments.select { |item| item.dig('user', 'type') == 'Bot' }
  end

  def receipt
    JSON.parse(CISkip::STATE.match(managed_comments.first.fetch('body'))[1])
  end
end
