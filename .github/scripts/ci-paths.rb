#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'

module CIPaths
  JOBS = %w[agent swift website].freeze
  DOCUMENTATION = %r{\A(?:
    (?:README|CONTRIBUTING|CODE_OF_CONDUCT|SECURITY)(?:\.zh-CN)?\.md|
    (?:agent-core|macos/AnotherYou|website|release)/README(?:\.zh-CN)?\.md|
    docs/.*\.(?:md|png|jpg|jpeg|svg|webp|gif|pdf)|
    output/imagegen/.*\.(?:md|png|jpg|jpeg|webp)
  )\z}x.freeze

  def self.jobs_for(paths)
    jobs = JOBS.to_h { |job| [job, false] }
    paths.each do |path|
      case path
      when %r{\A(?:\.github/|skills/|scripts/|agent-core/scripts/)}, 'Makefile', 'AGENTS.md'
        # 工作流、构建入口与自动化规范影响跨模块行为，不能按扩展名豁免。
        return JOBS.to_h { |job| [job, true] }
      when DOCUMENTATION
        next
      when %r{\Aagent-core/}
        jobs['agent'] = jobs['swift'] = true
      when %r{\Amacos/}
        jobs['swift'] = true
      when %r{\Awebsite/}
        jobs['website'] = true
      else
        return JOBS.to_h { |job| [job, true] }
      end
    end
    jobs
  end

  def self.all(reason)
    { 'jobs' => JOBS.to_h { |job| [job, true] }, 'reason' => reason }
  end

  def self.resolve(event_name, event, directory: Dir.pwd)
    if event_name == 'pull_request'
      base = event.dig('pull_request', 'base', 'sha')
      head = event.dig('pull_request', 'head', 'sha')
      separator = '...'
    elsif event_name == 'push'
      base = event['before']
      head = event['after']
      separator = '..'
    else
      return all('手动或未知事件，执行全部检查。')
    end

    unless [base, head].all? { |sha| sha.is_a?(String) && sha.match?(/\A[0-9a-f]{40}\z/) && sha != '0' * 40 }
      return all('缺少有效的比较提交，执行全部检查。')
    end

    # 不使用文件数受限的 API；关闭 rename 合并，保留移出代码目录的原路径。
    output, _, status = Open3.capture3('git', 'diff', '--no-renames', '--name-only', '-z', "#{base}#{separator}#{head}", '--', chdir: directory)
    return all('无法完整比较提交，执行全部检查。') unless status.success?

    paths = output.split("\0")
    { 'jobs' => jobs_for(paths), 'reason' => "已检查 #{paths.length} 个变更路径。" }
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    event = JSON.parse(File.read(ENV.fetch('GITHUB_EVENT_PATH')))
    plan = CIPaths.resolve(ENV.fetch('GITHUB_EVENT_NAME'), event)
  rescue JSON::ParserError, KeyError, Errno::ENOENT
    plan = CIPaths.all('无法读取事件信息，执行全部检查。')
  end
  File.open(ENV.fetch('GITHUB_OUTPUT'), 'a') do |file|
    plan.fetch('jobs').each { |job, enabled| file.puts "#{job}=#{enabled}" }
  end
  puts JSON.pretty_generate(plan)
end
