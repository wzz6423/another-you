#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative 'check-repository-hygiene'

class RepositoryHygieneTest < Minitest::Test
  def test_generated_paths_are_rejected
    %w[macos/AnotherYou/.build/debug/app dist/dev/Another.app macos/DerivedData/file agent-core/node_modules/pkg/index.js coverage/test.json reports/temporary.md scripts/__pycache__/file.pyc agent-core/.cache/runtime/node agent-core/.pi-data/settings.json .ci-trusted/.github/ci-skip.json agent-core/vendor/pi/README.md temp/test.o temp/test.dmg temp/test.app/Contents/MacOS/Test temp/test.framework/Test temp/test.xcresult/result .DS_Store macos/project.xcodeproj/xcuserdata/user.xcuserstate].each do |path|
      refute_nil RepositoryHygiene.path_violation(path), path
    end
  end

  def test_private_configuration_is_rejected_but_examples_and_release_config_are_allowed
    %w[.env .env.local agent-core/.env.production keys/developer.p12 keys/private.key].each do |path|
      refute_nil RepositoryHygiene.path_violation(path), path
    end
    %w[.env.example agent-core/.env.example agent-core/config.example.json release/config.json scripts/runtime-dependencies.json].each do |path|
      assert_nil RepositoryHygiene.path_violation(path), path
    end
  end

  def test_shipped_images_fonts_and_bundled_javascript_remain_allowed
    %w[macos/AnotherYou/Sources/AnotherYouCore/Resources/AppIcon.icns macos/AnotherYou/Sources/AnotherYouCore/Resources/BrandDark.png macos/AnotherYou/Sources/AnotherYouCore/Markdown/fonts/KaTeX_Main-Regular.woff2 macos/AnotherYou/Sources/AnotherYouCore/Markdown/render.js output/imagegen/another-you-logo-v8/another-you-dark.png].each do |path|
      assert_nil RepositoryHygiene.path_violation(path), path
    end
  end

  def test_compiled_blobs_are_rejected_even_when_not_executable_or_replaced_locally
    in_repository do |directory|
      %w[7f454c46 feedfacf cffaedfe cafebabe 4d5a].each_with_index do |hex, index|
        stage(directory, "temporary-#{index}", [hex].pack('H*') + 'payload')
        File.write(File.join(directory, "temporary-#{index}"), 'harmless working copy')
      end
      violations = RepositoryHygiene.check(directory: directory)
      assert_equal 5, violations.length
      assert violations.all? { |_, reason| reason == '编译后的 binary' }
    end
  end

  def test_only_git_tracked_or_staged_files_are_checked
    in_repository do |directory|
      stage(directory, 'scripts/test.sh', "#!/bin/bash\nprintf test\\n\n")
      File.write(File.join(directory, 'untracked.exe'), "MZbinary")
      assert_empty RepositoryHygiene.check(directory: directory)
    end
  end

  def test_staged_paths_with_spaces_newlines_and_deleted_working_files_are_checked
    in_repository do |directory|
      path = "报告 目录\n/.env.local"
      stage(directory, path, 'private fixture')
      FileUtils.rm(File.join(directory, path))
      assert_equal [[path, '私人环境配置']], RepositoryHygiene.check(directory: directory)
    end
  end

  private

  def in_repository
    Dir.mktmpdir('another-you-hygiene-') do |directory|
      output, status = Open3.capture2e('git', 'init', '-q', directory)
      assert status.success?, output
      yield directory
    end
  end

  def stage(directory, path, content)
    target = File.join(directory, path)
    FileUtils.mkdir_p(File.dirname(target))
    File.binwrite(target, content)
    output, status = Open3.capture2e('git', 'add', '--', path, chdir: directory)
    assert status.success?, output
  end
end
