# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)
require 'tmpdir'

class RedmineGttSyncAssetsTest < ActiveSupport::TestCase
  setup do
    @tmp = Dir.mktmpdir('gtt_sync_assets')
    @source = File.join(@tmp, 'assets')
    FileUtils.mkdir_p(File.join(@source, 'javascripts'))
    File.write(File.join(@source, 'javascripts', 'x.js'), 'current')
    @destination = File.join(@tmp, 'public', 'plugin_assets', 'redmine_gtt_sync')
  end

  teardown do
    FileUtils.remove_entry(@tmp)
  end

  def mirror
    RedmineGttSync::Assets.mirror(source: @source, destination: @destination)
  end

  def mirrored_js
    File.read(File.join(@destination, 'javascripts', 'x.js'))
  end

  test 'symlinks the assets into place on first boot' do
    mirror
    assert File.symlink?(@destination)
    assert_equal File.realpath(@source), File.realpath(@destination)
    assert_equal 'current', mirrored_js
  end

  test 'a matching symlink is left alone' do
    mirror
    before = File.lstat(@destination).ino
    mirror
    assert File.symlink?(@destination)
    assert_equal before, File.lstat(@destination).ino
  end

  test 'a stale symlink is repointed at the plugin assets' do
    elsewhere = File.join(@tmp, 'elsewhere')
    FileUtils.mkdir_p(File.dirname(@destination))
    FileUtils.mkdir_p(elsewhere)
    File.symlink(elsewhere, @destination)

    mirror
    assert_equal File.realpath(@source), File.realpath(@destination)
  end

  test 'falls back to a staged copy where symlinks are disallowed' do
    FileUtils.stubs(:ln_s).raises(Errno::EPERM)

    mirror
    refute File.symlink?(@destination)
    assert File.directory?(@destination)
    assert_equal 'current', mirrored_js
  end

  test 'refreshes an existing plain-directory copy in full' do
    # A previous copy fallback left a directory with stale content; the mirror
    # replaces it wholesale (staged swap), so removed files do not linger.
    FileUtils.mkdir_p(File.join(@destination, 'javascripts'))
    File.write(File.join(@destination, 'javascripts', 'x.js'), 'stale')
    File.write(File.join(@destination, 'javascripts', 'gone.js'), 'stale')

    mirror
    assert_equal 'current', mirrored_js
    refute File.exist?(File.join(@destination, 'javascripts', 'gone.js'))
  end

  test 'a missing source directory is a no-op' do
    RedmineGttSync::Assets.mirror(
      source: File.join(@tmp, 'no-such-dir'), destination: @destination
    )
    refute File.exist?(@destination)
  end
end
