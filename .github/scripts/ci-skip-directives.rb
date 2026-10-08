#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'set'
require 'time'
require 'uri'

module CISkip
  MARKER = '<!-- another-you-ci-skip -->'
  STATE = /<!-- ci-skip-state: (.*?) -->/
  PERMISSIONS = %w[admin maintain write].freeze

  def self.timestamp(value)
    Time.iso8601(value.to_s)
  rescue ArgumentError
    nil
  end

  def self.normalize(value)
    value.to_s.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/\A-+|-+\z/, '')
  end

  # 与 Zisla/Zshell 一样，只解析独立行上的指令，引用和示例不能触发操作。
  def self.directives(body)
    fence = nil
    body.to_s.gsub(/<!--.*?(?:-->|\z)/m, '').each_line.filter_map do |line|
      if fence
        fence = nil if line.match?(/\A {0,3}#{Regexp.escape(fence[0])}{#{fence.length},}\s*\z/)
        next
      end
      opening = /\A {0,3}(`{3,}|~{3,})/.match(line)
      if opening
        fence = opening[1]
        next
      end
      next if line.match?(/\A(?: {4}|\t|\s*>)/)

      match = /\A {0,3}((?:un)?skip)-([A-Za-z0-9].*)\s*\z/i.match(line.chomp)
      next unless match

      { 'skip' => match[1].casecmp('skip').zero?, 'target' => match[2].split(/[:,;!：]/, 2).first.strip }
    end
  end

  class Manifest
    attr_reader :workflows, :label

    def initialize(document)
      @workflows = document.fetch('workflows')
      @label = document.fetch('label')
      @aliases = {}
      raise 'CI manifest 没有目标。' if workflows.empty? || targets.empty?
      raise 'CI target id 重复。' unless ids.uniq == ids

      workflows.each do |workflow|
        raise 'CI workflow 文件名无效。' unless workflow.fetch('file').match?(/\A[a-z0-9-]+\.yml\z/)
        group = workflow.fetch('targets').map { |target| target.fetch('id') }
        raise 'CI workflow 目标为空或 id 无效。' if group.empty? || group.any? { |id| !id.match?(/\A[a-z][a-z0-9-]*\z/) }
        register([workflow.fetch('name'), workflow.fetch('file'), File.basename(workflow.fetch('file'), '.yml')] + workflow.fetch('aliases'), group)
        workflow.fetch('targets').each do |target|
          register([target.fetch('id'), target.fetch('name')] + target.fetch('aliases'), [target.fetch('id')])
        end
      end
    end

    def targets
      workflows.flat_map { |workflow| workflow.fetch('targets') }
    end

    def ids
      targets.map { |target| target.fetch('id') }
    end

    def workflow(name)
      workflows.find { |entry| entry.fetch('name') == name } || raise("未知工作流 #{name.inspect}")
    end

    def resolve_alias(text)
      words = text.split(/\s+/)
      words.length.downto(1) do |length|
        candidate = CISkip.normalize(words.take(length).join(' '))
        return ids if candidate == 'all'
        return @aliases.fetch(candidate) if @aliases.key?(candidate)
      end
      nil
    end

    private

    def register(names, values)
      names.each do |name|
        key = CISkip.normalize(name)
        raise "无效 CI 别名 #{name.inspect}" if key.empty? || key == 'all'
        raise "重复 CI 别名 #{name.inspect}" if @aliases.key?(key) && @aliases[key] != values

        @aliases[key] = values
      end
    end
  end

  def self.resolve(manifest, comments, permissions, seen_at)
    selected = Set.new
    restored = Set.new
    expired = 0
    unknown = 0
    authorized = 0
    comments.sort_by { |comment| [timestamp(comment['updated_at']) || Time.at(0), comment.fetch('id')] }.each do |comment|
      user = comment.fetch('user')
      next if user['type'] == 'Bot' || user.fetch('login').end_with?('[bot]')
      next unless PERMISSIONS.include?(permissions[user.fetch('login')])

      directives(comment['body']).each do |directive|
        authorized += 1
        affected = manifest.resolve_alias(directive.fetch('target'))
        if affected.nil?
          unknown += 1
          next
        end
        changed_at = timestamp(comment['updated_at'])
        # run.created_at 来自 GitHub；commit 的作者/提交者时间可回填，不能作为见到 head 的证据。
        if seen_at.nil? || changed_at.nil? || changed_at <= seen_at
          expired += 1
          next
        end
        if directive.fetch('skip')
          selected.merge(affected)
        else
          selected.subtract(affected)
          restored.merge(affected)
        end
      end
    end
    { 'targets' => manifest.ids.select { |id| selected.include?(id) }, 'restored' => restored.to_a, 'expired' => expired, 'unknown' => unknown, 'authorized' => authorized }
  end

  class API
    def request(method, path, body = nil)
      args = ['gh', 'api', '--method', method, path]
      args += ['--input', '-'] unless body.nil?
      output, _, status = Open3.capture3(*args, stdin_data: body.nil? ? '' : JSON.generate(body))
      raise "GitHub #{method} #{path} 请求失败。" unless status.success?

      output.empty? ? nil : JSON.parse(output)
    end

    def pages(path, key = nil)
      items = []
      page = 1
      loop do
        result = request('GET', "#{path}#{path.include?('?') ? '&' : '?'}per_page=100&page=#{page}")
        batch = key ? result.fetch(key) : result
        raise 'GitHub 分页结果无效。' unless batch.is_a?(Array)

        items.concat(batch)
        break if batch.length < 100

        page += 1
      end
      items
    end
  end

  class Controller
    def initialize(api:, manifest:, repository:, number:, pause: -> { sleep 5 }, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      raise 'GitHub 仓库名无效。' unless repository.match?(%r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z})
      raise 'PR 编号无效。' unless number.to_s.match?(/\A[1-9][0-9]*\z/)

      @api, @manifest, @repository, @number = api, manifest, repository, number.to_i
      @pause, @clock = pause, clock
    end

    def snapshot(recovery: false)
      pr = @api.request('GET', path("pulls/#{@number}"))
      head = pr.fetch('head').fetch('sha')
      raise 'PR head 无效。' unless head.match?(/\A[0-9a-f]{40}\z/)
      unless pr.fetch('state') == 'open'
        return { 'pr' => pr, 'head' => head, 'comments' => [], 'runs' => [], 'decision' => { 'targets' => [], 'restored' => [], 'expired' => 0, 'unknown' => 0, 'authorized' => 0 } }
      end

      comments = @api.pages(path("issues/#{@number}/comments"))
      permissions = {}
      comments.each do |comment|
        user = comment.fetch('user')
        next if user['type'] == 'Bot' || user.fetch('login').end_with?('[bot]') || CISkip.directives(comment['body']).empty?

        login = user.fetch('login')
        permissions[login] ||= @api.request('GET', path("collaborators/#{URI.encode_www_form_component(login)}/permission")).fetch('permission')
      end
      runs = []
      managed = !managed_comments(comments).empty?
      labeled = pr.fetch('labels').any? { |label| label.fetch('name').casecmp?(@manifest.label) }
      if recovery || managed || labeled || permissions.values.any? { |permission| PERMISSIONS.include?(permission) }
        candidates = @api.pages(path("pulls?state=all&head=#{URI.encode_www_form_component("#{pr.dig('head', 'repo', 'owner', 'login')}:#{pr.dig('head', 'ref')}")}"))
        runs = @api.pages(path("actions/runs?event=pull_request&head_sha=#{head}"), 'workflow_runs')
                   .select { |run| matching_run?(run, pr, candidates) }
      end
      seen_at = runs.filter_map { |run| CISkip.timestamp(run['created_at']) }.min
      decision = CISkip.resolve(@manifest, comments, permissions, seen_at)
      decision['targets'] = [] unless pr.fetch('state') == 'open'
      { 'pr' => pr, 'head' => head, 'comments' => comments, 'runs' => runs, 'decision' => decision }
    end

    def gate(workflow_name, expected_head)
      state = snapshot
      return { 'skip' => false, 'targets' => [], 'head-sha' => state.fetch('head') } unless state.fetch('head') == expected_head

      selected = state.fetch('decision').fetch('targets')
      receipt = previous_state(managed_comments(state.fetch('comments')).min_by { |comment| comment.fetch('id') })
      # gate 不能在写入可恢复记录前跳过；摘要不授予权限，仍取实时有效评论的交集。
      recorded = receipt['head'] == state.fetch('head') && %w[pending applied].include?(receipt['status']) ? Array(receipt['targets']) : []
      selected &= recorded
      ids = @manifest.workflow(workflow_name).fetch('targets').map { |target| target.fetch('id') }
      { 'skip' => ids.all? { |id| selected.include?(id) }, 'targets' => selected, 'head-sha' => state.fetch('head') }
    end

    def apply(deleted_summary: nil)
      recovery = !deleted_summary.to_s.empty?
      state = snapshot(recovery: recovery)
      return unless state.fetch('pr').fetch('state') == 'open'

      head, decision = state.values_at('head', 'decision')
      managed = managed_comments(state.fetch('comments'))
      existing = managed.min_by { |comment| comment.fetch('id') }
      labeled = state.fetch('pr').fetch('labels').any? { |label| label.fetch('name').casecmp?(@manifest.label) }
      return if existing.nil? && decision.fetch('authorized').zero? && !labeled && !recovery

      old = previous_state(existing || { 'body' => deleted_summary.to_s })
      before = old['head'] == head ? Array(old['targets']) : []
      pending = old['head'] == head ? Array(old['pending']) : []
      before = @manifest.ids if old['head'].nil? && labeled
      before |= decision.fetch('restored') if existing.nil?
      changed = (before - decision.fetch('targets')) + (decision.fetch('targets') - before)
      pending |= @manifest.workflows.filter_map do |workflow|
        workflow.fetch('file') unless (workflow.fetch('targets').map { |target| target.fetch('id') } & changed).empty?
      end
      pending &= @manifest.workflows.map { |workflow| workflow.fetch('file') }
      ensure_current_head!(head)
      existing = write_summary(existing, summary(head, decision, pending: pending))
      pending.dup.each do |file|
        runs = state.fetch('runs').select { |run| run.fetch('path') == ".github/workflows/#{file}" }

        run = runs.max_by { |item| [CISkip.timestamp(item.fetch('created_at')), item.fetch('id')] }
        restart(run, head) if run
        pending.delete(file)
        existing = write_summary(existing, summary(head, decision, pending: pending))
      end
      ensure_current_head!(head)
      synchronize_label(state.fetch('pr'), !decision.fetch('targets').empty?)
      managed.reject { |comment| comment.fetch('id') == existing.fetch('id') }.each { |comment| @api.request('DELETE', path("issues/comments/#{comment.fetch('id')}")) }
    end

    def matching_run?(run, pr, candidates)
      return false unless run['event'] == 'pull_request' && run['head_sha'] == pr.dig('head', 'sha')
      return false unless run['head_branch'] == pr.dig('head', 'ref')
      return false unless run.dig('head_repository', 'id') && run.dig('head_repository', 'id') == pr.dig('head', 'repo', 'id')
      return false unless run.dig('head_repository', 'full_name') == pr.dig('head', 'repo', 'full_name')
      return false unless @manifest.workflows.any? { |workflow| run['path'] == ".github/workflows/#{workflow.fetch('file')}" }

      created = CISkip.timestamp(run['created_at'])
      opened = CISkip.timestamp(pr['created_at'])
      return false if created.nil? || opened.nil? || created < opened

      attached = Array(run['pull_requests']).map { |item| item.fetch('number') }.uniq
      return attached == [@number] unless attached.empty?

      # 部分真实 PR run 的 pull_requests 为空；只有其创建时唯一开放的同源 PR 才可归属。
      possible = candidates.select do |candidate|
        start = CISkip.timestamp(candidate['created_at'])
        finish = CISkip.timestamp(candidate['closed_at'])
        candidate.dig('head', 'repo', 'id') == pr.dig('head', 'repo', 'id') &&
          candidate.dig('head', 'ref') == pr.dig('head', 'ref') &&
          start && start <= created && (candidate['closed_at'].nil? || (finish && finish > created))
      end
      possible.map { |candidate| candidate.fetch('number') }.uniq == [@number]
    end

    private

    def path(suffix)
      "repos/#{@repository}/#{suffix}"
    end

    def previous_state(comment)
      encoded = comment && STATE.match(comment.fetch('body'))
      parsed = encoded ? JSON.parse(encoded[1]) : {}
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end

    def managed_comments(comments)
      comments.select { |comment| comment.dig('user', 'login') == 'github-actions[bot]' && comment.dig('user', 'type') == 'Bot' && comment.fetch('body').to_s.start_with?(MARKER) }
    end

    def write_summary(existing, body)
      if existing
        @api.request('PATCH', path("issues/comments/#{existing.fetch('id')}"), { 'body' => body }) unless existing.fetch('body') == body
        existing.merge('body' => body)
      else
        @api.request('POST', path("issues/#{@number}/comments"), { 'body' => body })
      end
    end

    def ensure_current_head!(expected)
      current = @api.request('GET', path("pulls/#{@number}"))
      raise 'PR 已关闭或 head 已改变；停止对旧决定操作，请等待新提交的检查。' unless current['state'] == 'open' && current.dig('head', 'sha') == expected
    end

    def restart(run, head)
      ensure_current_head!(head)
      endpoint = path("actions/runs/#{run.fetch('id')}")
      current = @api.request('GET', endpoint)
      raise '工作流 run 的提交已改变。' unless current['head_sha'] == head

      unless current.fetch('status') == 'completed'
        begin
          @api.request('POST', "#{endpoint}/cancel")
        rescue StandardError
          raise unless @api.request('GET', endpoint).fetch('status') == 'completed'
        end
        deadline = @clock.call + 300
        loop do
          ensure_current_head!(head)
          break if @api.request('GET', endpoint).fetch('status') == 'completed'
          raise '取消工作流超时，未重跑，也未写入成功检查。' if @clock.call >= deadline

          @pause.call
        end
      end
      ensure_current_head!(head)
      @api.request('POST', "#{endpoint}/rerun")
    end

    def synchronize_label(pr, selected)
      present = pr.fetch('labels').find { |label| label.fetch('name').casecmp?(@manifest.label) }
      if selected && !present
        labels = @api.pages(path('labels'))
        unless labels.any? { |label| label.fetch('name').casecmp?(@manifest.label) }
          begin
            @api.request('POST', path('labels'), { 'name' => @manifest.label, 'color' => 'FBCA04', 'description' => 'Maintainer CI skip directives apply to this PR head.' })
          rescue StandardError
            raise unless @api.pages(path('labels')).any? { |label| label.fetch('name').casecmp?(@manifest.label) }
          end
        end
        @api.request('POST', path("issues/#{@number}/labels"), { 'labels' => [@manifest.label] })
      elsif !selected && present
        @api.request('DELETE', path("issues/#{@number}/labels/#{URI.encode_www_form_component(present.fetch('name'))}"))
      end
    end

    def summary(head, decision, pending: [])
      selected = @manifest.targets.select { |target| decision.fetch('targets').include?(target.fetch('id')) }.map { |target| "`#{target.fetch('name')}`" }
      receipt = { 'head' => head, 'targets' => decision.fetch('targets'), 'pending' => pending, 'status' => pending.empty? ? 'applied' : 'pending' }
      lines = [MARKER, "<!-- ci-skip-state: #{JSON.generate(receipt)} -->", '', '### CI 跳过指令 / CI skip directives', '', "当前提交 / Current head: `#{head}`", '']
      lines << (selected.empty? ? '没有生效的跳过指令。 / No skip directive is active.' : "已选择跳过 / Selected skips: #{selected.join(', ')}.")
      lines << '' << "正在应用，可重试恢复 / Applying; safe to retry: #{pending.map { |file| "`#{file}`" }.join(', ')}." unless pending.empty?
      lines << '' << '受影响工作流通过取消后真实重跑应用决定；未跳过的检查仍须通过。未启动的工作流在首次运行时读取决定。 / Affected runs are cancelled and rerun; every unskipped check must still pass. Future runs read the decision at their gate.'
      lines << '' << '无法确认评论发出前当前 head 已出现的指令已忽略（包括同秒和多 PR 归属不明）。请等待当前 PR 的 CI 开始后重新评论。 / Directives without unambiguous evidence that this PR head existed before the comment were ignored. Comment again after its CI starts.' if decision.fetch('expired').positive?
      lines << '' << "未识别的目标 / Unknown targets ignored: #{decision.fetch('unknown')}." if decision.fetch('unknown').positive?
      lines << '' << '使用 `unskip-all` 或 `unskip-<target>` 恢复。新提交使旧决定失效。 / Use `unskip-all` or `unskip-<target>` to restore checks. A new head expires prior directives.'
      lines.join("\n") + "\n"
    end
  end
end

if $PROGRAM_NAME == __FILE__
  mode = ARGV.fetch(0)
  fallback = { 'skip' => false, 'targets' => [], 'head-sha' => '' }
  begin
    manifest = CISkip::Manifest.new(JSON.parse(File.read(File.expand_path('../ci-skip.json', __dir__))))
    if mode == 'gate' && ENV.fetch('PR_NUMBER', '').empty?
      decision = fallback
    else
      controller = CISkip::Controller.new(api: CISkip::API.new, manifest: manifest, repository: ENV.fetch('GITHUB_REPOSITORY'), number: ENV.fetch('PR_NUMBER'))
      case mode
      when 'gate'
        decision = controller.gate(ENV.fetch('WORKFLOW_NAME'), ENV.fetch('EXPECTED_HEAD_SHA'))
      when 'apply'
        controller.apply(deleted_summary: ENV['CI_SKIP_DELETED_SUMMARY'])
      else
        raise "未知命令 #{mode.inspect}"
      end
    end
  rescue StandardError => error
    raise unless mode == 'gate'

    warn "CI skip gate 无法确认跳过条件，正常执行所有检查：#{error.message}"
    decision = fallback
  end
  if mode == 'gate'
    File.open(ENV.fetch('GITHUB_OUTPUT'), 'a') do |file|
      decision.each { |key, value| file.puts "#{key}=#{value.is_a?(Array) ? JSON.generate(value) : value}" }
    end
  end
end
