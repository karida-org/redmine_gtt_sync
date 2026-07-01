require File.expand_path('../../test_helper', __FILE__)

class RedmineGttSyncPluginTest < ActiveSupport::TestCase
  def test_plugin_is_registered
    assert Redmine::Plugin.installed?(:redmine_gtt_sync)
  end

  def test_requires_redmine_gtt
    plugin = Redmine::Plugin.find(:redmine_gtt_sync)
    required = plugin.requirements[:redmine_plugins] || {}
    assert_includes required.keys, :redmine_gtt
  end
end
