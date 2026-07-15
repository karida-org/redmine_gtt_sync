# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

class RedmineGttSyncPluginTest < ActiveSupport::TestCase
  def test_plugin_is_registered
    assert Redmine::Plugin.installed?(:redmine_gtt_sync)
  end

  def test_redmine_gtt_dependency_present
    # init.rb enforces the dependency at load via requires_redmine_plugin, which
    # raises if redmine_gtt is missing. Redmine::Plugin exposes no public reader
    # for the recorded requirements, so assert the dependency through the public
    # installed? API instead of reaching into internal state.
    assert Redmine::Plugin.installed?(:redmine_gtt),
           'redmine_gtt must be installed; redmine_gtt_sync depends on it'
  end
end
