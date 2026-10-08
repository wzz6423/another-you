#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require 'yaml'
require_relative 'pr-metadata'

class PullRequestMetadataTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CONTRACT_PATH = File.expand_path('../pr-automation.json', __dir__)
  TITLE = 'ci(github): validate contribution metadata'

  def setup
    @contract = PullRequestMetadata::Contract.load(CONTRACT_PATH)
  end

  def test_complete_body_needs_no_project_schedule_or_ai_attribution
    assert_empty validate
    metadata = PullRequestMetadata.analyze(title: TITLE, body: body, contract: @contract)
    assert metadata['valid']
    assert_equal ['ci'], metadata['labels']
    assert_includes metadata['managedLabels'], 'needs-more-info'
    refute body.include?('GitHub Project')
    refute body.include?('AI Attribution')
  end

  def test_every_type_maps_to_its_declared_label
    JSON.parse(File.read(CONTRACT_PATH)).fetch('types').each do |entry|
      metadata = PullRequestMetadata.analyze(title: "#{entry['type']}(github): update contribution checks", body: body(type: entry['type']), contract: @contract)
      assert metadata['valid'], metadata['errors'].join("\n")
      assert_equal entry['label'], metadata['typeLabel']
      assert_equal [entry['label']], metadata['labels']
    end
  end

  def test_title_requires_an_english_conventional_commit_and_explicit_scope_format
    ['Add a quality gate', 'ci: 增加质量检查', 'feature: add checks', 'ci(): add checks',
     'ci(GitHub): add checks', 'ci(github_actions): add checks', 'ci(github.actions): add checks',
     'ci: ', 'ci: ...', 'ci: 12345', 'ci: TBD', 'ci: <description>'].each do |title|
      assert_includes validate(title: title).join("\n"), 'English Conventional Commit', title
    end
    ['ci: add checks', 'ci(github-actions): add checks', 'ci!: change required metadata', 'ci(github-actions)!: change required metadata'].each do |title|
      assert_empty validate(title: title), title
    end
  end

  def test_body_type_must_be_one_canonical_type_matching_the_title
    ['bug', 'CI', 'ci,fix', '', 'TBD', '<!-- ci -->', "ci\n- Type:", "ci\n- Type: ci"].each do |type|
      assert_includes validate(type: type).join("\n"), 'exactly one', type
    end
    assert_includes validate(type: 'fix').join("\n"), 'does not match the title type'
  end

  def test_every_required_section_is_reported_when_missing
    errors = PullRequestMetadata.validate(title: TITLE, body: '', contract: @contract).join("\n")
    PullRequestMetadata::REQUIRED_SECTIONS.each { |section| assert_includes errors, "## #{section}" }
  end

  def test_empty_commented_or_placeholder_summary_is_invalid
    ['', ' ', '<!-- Explain why. -->', '<!-- unclosed', '-', '- [ ]', '- [x]', '1.', '...', 'TBD', 'N/A', '<description>'].each do |summary|
      assert_includes validate(summary: summary).join("\n"), 'Summary must include', summary
    end
    assert_empty validate(summary: '明确要求每一项测试独立填写结果。')
  end

  def test_duplicate_sections_are_invalid_even_when_the_duplicate_is_empty
    PullRequestMetadata::REQUIRED_SECTIONS.each do |section|
      errors = PullRequestMetadata.validate(title: TITLE, body: "#{body}\n## #{section}\n", contract: @contract)
      assert_includes errors.join("\n"), "Section \"## #{section}\" must appear exactly once."
    end
  end

  def test_fenced_commented_and_indented_bodies_cannot_supply_required_sections
    ["```markdown\n#{body}\n```", "~~~~markdown\n#{body}\n~~~~", "<!--\n#{body}\n-->",
     body.lines.map { |line| "    #{line}" }.join, body.lines.map { |line| "> #{line}" }.join].each do |example|
      errors = PullRequestMetadata.validate(title: TITLE, body: example, contract: @contract)
      assert_includes errors.join("\n"), 'Missing required section(s)'
    end
  end

  def test_code_fields_do_not_satisfy_an_existing_section
    ['```', '~~~'].each do |fence|
      validation = "#{fence}\n- Status: passed\n- Command: make test-ci\n- Result: 12 passed.\n#{fence}"
      assert_includes validate(validation: validation).join("\n"), 'Validation must declare a Status'
    end
    assert_includes validate(validation: "- Status: passed\n```\n- Command: make test-ci\n- Result: 12 passed.\n```").join("\n"), 'non-empty Command'
  end

  def test_shorter_fence_and_fence_with_text_do_not_close_a_code_block
    example = "````markdown\n```\n#{body}\n````"
    assert_includes PullRequestMetadata.validate(title: TITLE, body: example, contract: @contract).join("\n"), 'Missing required section(s)'
    example = "~~~markdown\n~~~more text\n#{body}\n~~~"
    assert_includes PullRequestMetadata.validate(title: TITLE, body: example, contract: @contract).join("\n"), 'Missing required section(s)'
  end

  def test_comments_are_ignored_without_losing_neighboring_content
    complete = body.gsub('- Status: passed', '- Status: passed <!-- selected -->')
    complete += "\n<!--\n## PR Type\n- Type: fix\n-->\n"
    complete.gsub!("\n", "\r\n")
    assert_empty PullRequestMetadata.validate(title: TITLE, body: complete, contract: @contract)
  end

  def test_validation_entries_are_independent_for_every_status
    validation = "- Status: passed\n- Command: make check-ci\n- Result: All syntax checks passed.\n\n" \
                 "- Status: failed\n- Command: make test-ci\n- Result: One test failed because a fixture is missing.\n\n" \
                 "- Status: not run\n- Reason: UI behavior is unchanged."
    assert_empty validate(validation: validation)
    { 'passed' => %w[Command Result], 'failed' => %w[Command Result], 'not run' => ['Reason'] }.each do |status, fields|
      entry = "- Status: #{status}"
      complete = "- Status: passed\n- Command: make test-ci\n- Result: 12 passed.\n- Reason: This belongs to the complete entry."
      ["#{entry}\n#{complete}", "#{complete}\n#{entry}"].each_with_index do |text, index|
        errors = validate(validation: text).join("\n")
        fields.each { |field| assert_includes errors, "Validation entry #{index + 1} must include a non-empty #{field}" }
      end
    end
  end

  def test_each_status_rejects_placeholders_and_unknown_values
    ['', 'skipped', 'success', 'Passed', '<!-- passed -->', 'passed | failed | not run'].each do |status|
      validation = "- Status: passed\n- Command: make check-ci\n- Result: All passed.\n- Status: #{status}"
      assert_includes validate(validation: validation).join("\n"), 'Validation entry 2 must declare one exact status'
    end
  end

  def test_required_validation_fields_reject_placeholders
    { 'passed' => %w[Command Result], 'failed' => %w[Command Result], 'not run' => ['Reason'] }.each do |status, fields|
      ['', '<!-- required -->', 'TBD', '...', '<command>'].each do |value|
        validation = "- Status: #{status}\n- Command: #{value}\n- Result: #{value}\n- Reason: #{value}"
        errors = validate(validation: validation).join("\n")
        fields.each { |field| assert_includes errors, "non-empty #{field}" }
      end
    end
  end

  def test_duplicate_validation_fields_include_empty_duplicates
    %w[Command Result Reason].product(['', '<!-- unused -->', 'Another value.']).each do |field, value|
      validation = "- Status: passed\n- Command: make test-ci\n- Result: 12 passed.\n- Reason: Additional context.\n- #{field}: #{value}"
      assert_includes validate(validation: validation).join("\n"), "at most one #{field} field"
    end
  end

  def test_unused_optional_validation_fields_may_remain_blank
    assert_empty validate(validation: "- Status: not run\n- Command: <!-- unused -->\n- Result:\n- Reason: No runtime behavior changed.")
    assert_empty validate(validation: "- Status: passed\n- Command: make check-ci\n- Result: All checks passed.\n- Reason:")
  end

  def test_validation_fields_before_their_status_are_invalid
    validation = "- Command: make test-ci\n- Result: 12 passed.\n- Status: not run\n- Reason: No native UI changes."
    assert_includes validate(validation: validation).join("\n"), 'must follow their own Status'
  end

  def test_risk_and_rollback_require_exactly_one_non_empty_field_each
    %w[Risk Rollback].each do |field|
      ['', '<!-- fill in -->', 'TBD', '<description>'].each do |value|
        text = body.sub(/^- #{field}:.*$/, "- #{field}: #{value}")
        assert_includes PullRequestMetadata.validate(title: TITLE, body: text, contract: @contract).join("\n"), "one non-empty #{field}"
      end
      ['', 'A second value.'].each do |value|
        text = body.sub(/(^- #{field}:.*$)/, "\\1\n- #{field}: #{value}")
        assert_includes PullRequestMetadata.validate(title: TITLE, body: text, contract: @contract).join("\n"), "one non-empty #{field}"
      end
    end
  end

  def test_related_issues_accept_explicit_closing_references
    related = "Closes #123\n- Fixes https://github.com/wzz6423/another-you/issues/42.\nResolves wzz6423/another-you#7"
    metadata = PullRequestMetadata.analyze(title: TITLE, body: body(related: related), contract: @contract)
    assert metadata['valid'], metadata['errors'].join("\n")
    assert_equal [7, 42, 123], metadata['issues']
    assert_includes metadata['labels'], 'development'
  end

  def test_related_issue_rejects_ambiguous_or_example_references
    ['See #123', '`Closes #123`', 'unfixes #123', 'Closes #0', 'Closes #123suffix',
     "None\nCloses #123", "None\nExtra text", "- None\n- None", 'Closes #123, #456',
     "```\nCloses #123\n```", '<!-- Closes #123 -->'].each do |related|
      assert_includes validate(related: related).join("\n"), 'one closing reference per line', related
    end
    metadata = PullRequestMetadata.analyze(title: TITLE, body: body(related: "None\n<!-- Closes #123 -->"), contract: @contract)
    assert metadata['valid']
    assert_empty metadata['issues']
    refute_includes metadata['labels'], 'development'
  end

  def test_fixing_metadata_clears_needs_more_info
    invalid = PullRequestMetadata.analyze(title: TITLE, body: body(type: ''), contract: @contract)
    valid = PullRequestMetadata.analyze(title: TITLE, body: body, contract: @contract)
    assert_includes invalid['labels'], 'needs-more-info'
    refute_includes valid['labels'], 'needs-more-info'
    assert_includes valid['managedLabels'], 'needs-more-info'
  end

  def test_shipped_template_is_invalid_until_required_values_are_filled
    template = File.read(File.join(ROOT, '.github/PULL_REQUEST_TEMPLATE.md'))
    refute_empty PullRequestMetadata.validate(title: TITLE, body: template, contract: @contract)
    complete = template.sub('<!-- Describe the problem, final behavior, and changed scope. English or Chinese is welcome. -->', 'Validate contribution metadata on pull requests.')
                       .sub(/^- Type:.*$/, '- Type: ci')
                       .sub(/^- Status:.*$/, '- Status: not run')
                       .sub(/^- Reason:.*$/, '- Reason: The change only affects metadata parsing.')
                       .sub(/^- Risk:.*$/, '- Risk: Contributor forms may need more detail.')
                       .sub(/^- Rollback:.*$/, '- Rollback: Revert this pull request.')
    metadata = PullRequestMetadata.analyze(title: TITLE, body: complete, contract: @contract)
    assert metadata['valid'], metadata['errors'].join("\n")
    assert_empty metadata['issues']
  end

  def test_both_contributing_examples_pass_the_actual_contract
    %w[CONTRIBUTING.md CONTRIBUTING.zh-CN.md].each do |name|
      document = File.read(File.join(ROOT, name))
      example = document[/```markdown\n(.*?)\n```/m, 1]
      refute_nil example, "#{name} must include a complete PR example."
      errors = PullRequestMetadata.validate(title: 'docs: clarify contribution validation', body: example, contract: @contract)
      assert_empty errors, "#{name}: #{errors.join('; ')}"
    end
  end

  def test_json_cli_returns_invalid_metadata_without_failing_or_echoing_body
    with_files(body(type: '').sub('Add contribution metadata validation.', 'SENSITIVE_TEST_FIXTURE')) do |args|
      output, status = Open3.capture2e('ruby', File.join(__dir__, 'pr-metadata.rb'), 'json', *args)
      assert status.success?, output
      metadata = JSON.parse(output)
      assert_equal false, metadata['valid']
      assert_includes metadata['labels'], 'needs-more-info'
      refute_includes output, 'SENSITIVE_TEST_FIXTURE'
      output, status = Open3.capture2e('ruby', File.join(__dir__, 'pr-metadata.rb'), 'validate', *args)
      refute status.success?, output
      assert_includes output, 'PR Type'
    end
  end

  def test_cli_requires_both_metadata_files
    %w[json validate].each do |command|
      output, status = Open3.capture2e('ruby', File.join(__dir__, 'pr-metadata.rb'), command)
      refute status.success?
      assert_includes output, '--title-file and --body-file are required'
    end
  end

  def test_label_contract_is_complete_unique_and_matches_cli_shape
    output, status = Open3.capture2e('ruby', File.join(__dir__, 'pr-metadata.rb'), 'labels')
    assert status.success?, output
    labels = JSON.parse(output)
    assert_equal @contract.managed_label_names, labels.map { |entry| entry['label'] }
    assert_equal labels.length, labels.map { |entry| entry['label'] }.uniq.length
    labels.each do |entry|
      assert_equal %w[color description label], entry.keys.sort
      assert_match(/\A[0-9a-f]{6}\z/, entry['color'])
      refute_empty entry['description']
    end
  end

  def test_actual_quality_workflow_accepts_complete_body_and_cleans_up
    output, status = run_quality_step(body)
    assert status.success?, output
    assert_includes output, 'Pull request metadata is valid.'
  end

  def test_actual_quality_workflow_rejects_comment_only_or_duplicate_fields
    [body(type: '<!-- ci -->'), body(type: "ci\n- Type:"), body(validation: '- Status: passed')].each do |text|
      output, status = run_quality_step(text)
      refute status.success?, output
    end
  end

  def test_quality_workflow_runs_for_forks_with_only_read_permissions
    workflow = YAML.load_file(File.join(ROOT, '.github/workflows/pr-quality-gates.yml'))
    triggers = workflow['on'] || workflow[true]
    assert triggers.key?('pull_request')
    refute triggers.key?('pull_request_target')
    assert_includes triggers['pull_request']['types'], 'edited'
    assert_equal({ 'contents' => 'read' }, workflow['permissions'])
    gate = workflow['jobs'].fetch('gate')
    assert_equal({ 'contents' => 'read', 'pull-requests' => 'read', 'actions' => 'read' }, gate.fetch('permissions'))
    assert_equal 'gate', workflow['jobs']['validate']['needs']
    condition = workflow['jobs']['validate']['if']
    assert_includes condition, "needs.gate.result != 'success'"
    refute_includes condition, 'pull_request.user'
    checkout = workflow['jobs']['validate']['steps'].find { |step| step.key?('uses') }
    assert_equal false, checkout['with']['persist-credentials']
  end

  def test_quality_workflow_fails_if_the_skip_gate_failed
    workflow = YAML.load_file(File.join(ROOT, '.github/workflows/pr-quality-gates.yml'))
    step = workflow['jobs']['validate']['steps'].find { |entry| entry['name'] == 'Require a successful skip gate' }
    %w[failure skipped].each do |result|
      output, status = Open3.capture2e({ 'GATE_RESULT' => result }, 'bash', '-e', '-c', step.fetch('run'))
      refute status.success?, output
    end
    output, status = Open3.capture2e({ 'GATE_RESULT' => 'success' }, 'bash', '-e', '-c', step.fetch('run'))
    assert status.success?, output
  end

  def test_only_dependabot_skips_the_human_metadata_step
    workflow = YAML.load_file(File.join(ROOT, '.github/workflows/pr-quality-gates.yml'))
    steps = workflow['jobs']['validate']['steps']
    validate = steps.find { |step| step['name'] == 'Validate title and body' }
    exemption = steps.find { |step| step['name'] == 'Explain Dependabot metadata exemption' }
    assert_equal "github.event.pull_request.user.type != 'Bot' || github.event.pull_request.user.login != 'dependabot[bot]'", validate['if']
    assert_equal "github.event.pull_request.user.type == 'Bot' && github.event.pull_request.user.login == 'dependabot[bot]'", exemption['if']
    assert_equal 'test "$GATE_RESULT" = success', steps.first['run']
  end

  private

  def validate(title: TITLE, **values)
    PullRequestMetadata.validate(title: title, body: body(**values), contract: @contract)
  end

  def body(type: 'ci', summary: 'Add contribution metadata validation.', validation: nil, related: 'None')
    <<~BODY
      ## Summary

      #{summary}

      ## PR Type

      - Type: #{type}

      ## Validation

      #{validation || "- Status: passed\n- Command: ruby .github/scripts/pr-metadata-test.rb\n- Result: All contract tests passed."}

      ## Risk and Rollback

      - Risk: Repository automation changes may reject incomplete submissions.
      - Rollback: Revert this pull request.

      ## Related Issue

      #{related}
    BODY
  end

  def with_files(text)
    Dir.mktmpdir('another-you-pr-contract-') do |directory|
      title_file = File.join(directory, 'title.txt')
      body_file = File.join(directory, 'body.md')
      File.write(title_file, TITLE)
      File.write(body_file, text)
      yield ['--title-file', title_file, '--body-file', body_file]
    end
  end

  def run_quality_step(text)
    workflow = YAML.load_file(File.join(ROOT, '.github/workflows/pr-quality-gates.yml'))
    steps = workflow.fetch('jobs').fetch('validate').fetch('steps')
    run = steps.find { |step| step['name'] == 'Validate title and body' }.fetch('run')
    cleanup = steps.find { |step| step['name'] == 'Remove pull request metadata files' }.fetch('run')
    Dir.mktmpdir('another-you-pr-quality-') do |directory|
      env = { 'PR_TITLE' => TITLE, 'PR_BODY' => text, 'RUNNER_TEMP' => directory }
      result = Open3.capture2e(env, 'bash', '--noprofile', '--norc', '-e', '-o', 'pipefail', '-c', run, chdir: ROOT)
      output, status = Open3.capture2e(env, 'bash', '--noprofile', '--norc', '-e', '-c', cleanup, chdir: ROOT)
      assert status.success?, output
      assert_empty Dir.children(directory)
      result
    end
  end
end
