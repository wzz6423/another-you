#!/usr/bin/env ruby
# frozen_string_literal: true

require 'open3'

module RepositoryHygiene
  GENERATED_DIRECTORY = %r{(?:\A|/)(?:\.build|dist|DerivedData|node_modules|coverage|__pycache__|\.cache|\.pi-data|\.ci-trusted|reports|Reports|\.impeccable)(?:/|\z)}.freeze
  GENERATED_FILE = /\.(?:o|obj|a|dylib|so|dll|exe|pdb|dmg|pkg|zip|pyc|gcda|gcno|gcov|profdata|profraw|swiftdoc|swiftmodule|swiftsourceinfo)\z/.freeze
  BUNDLE = /\.(?:app|dSYM|framework|xcframework|xcarchive|xcresult)(?:\/|\z)/.freeze
  BINARY_MAGIC = ["\x7fELF", 'MZ', "\xfe\xed\xfa\xce", "\xce\xfa\xed\xfe", "\xfe\xed\xfa\xcf", "\xcf\xfa\xed\xfe", "\xca\xfe\xba\xbe", "\xbe\xba\xfe\xca", "\xca\xfe\xba\xbf", "\xbf\xba\xfe\xca", '!<arch>'].map(&:b).freeze

  def self.path_violation(path)
    return '构建、测试或过程产物目录' if path.match?(GENERATED_DIRECTORY)
    return 'Pi 上游源码缓存' if path.start_with?('agent-core/vendor/pi/')
    return '生成的构建产物' if path.match?(GENERATED_FILE) || path.match?(BUNDLE)
    return 'macOS 本机元数据' if File.basename(path) == '.DS_Store' || path.match?(%r{(?:\A|/)xcuserdata/})
    return '私人环境配置' if File.basename(path).match?(/\A\.env(?:\..+)?\z/) && File.basename(path) != '.env.example'
    return '签名或私钥文件' if path.match?(/\.(?:p12|pfx|key|mobileprovision)\z/)

    nil
  end

  def self.check(directory: Dir.pwd)
    output, error, status = Open3.capture3('git', 'ls-files', '--stage', '-z', chdir: directory)
    raise error unless status.success?

    violations = []
    # 读取暂存的 blob，避免工作区覆盖或删除文件后掩盖将要提交的 binary。
    IO.popen(['git', '-C', directory, 'cat-file', '--batch'], 'r+b') do |objects|
      output.split("\0").each do |entry|
        metadata, path = entry.split("\t", 2)
        mode, object, stage = metadata.split(' ')
        reason = path_violation(path)
        reason ||= '尚未解决的合并冲突' unless stage == '0'
        if reason
          violations << [path, reason]
          next
        end
        next if mode == '160000'

        objects.puts(object)
        objects.flush
        header = objects.gets&.split(' ')
        raise "无法读取 Git 对象 #{object}" unless header && header[1] == 'blob'

        remaining = Integer(header.fetch(2))
        prefix = objects.read([remaining, 8].min).to_s.b
        remaining -= prefix.bytesize
        while remaining.positive?
          chunk = objects.read([remaining, 65_536].min)
          raise "Git 对象 #{object} 不完整" if chunk.nil? || chunk.empty?

          remaining -= chunk.bytesize
        end
        raise "Git 对象 #{object} 分隔符无效" unless objects.read(1) == "\n"

        violations << [path, '编译后的 binary'] if BINARY_MAGIC.any? { |magic| prefix.start_with?(magic) }
      end
      objects.close_write
    end
    raise '无法完成 Git 对象检查' unless $?.success?

    violations
  end
end

if $PROGRAM_NAME == __FILE__
  violations = RepositoryHygiene.check
  violations.each { |path, reason| warn "禁止提交#{reason}：#{path.inspect}" }
  abort "仓库卫生检查失败：#{violations.length} 项。" unless violations.empty?

  puts '仓库卫生检查通过。'
end
