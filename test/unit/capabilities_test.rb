require File.expand_path('../../test_helper', __FILE__)

class RedmineGttSyncCapabilitiesTest < ActiveSupport::TestCase
  def setup
    @report = RedmineGttSync::Capabilities.report
  end

  def test_identifies_the_plugin_and_version
    assert_equal 'redmine_gtt_sync', @report[:plugin]
    assert_equal Redmine::Plugin.find(:redmine_gtt_sync).version, @report[:version]
  end

  def test_reports_the_runtime_versions
    assert_equal Redmine::VERSION.to_s, @report[:redmine][:version]
    assert_equal Rails.version, @report[:redmine][:rails]
  end

  def test_base_capabilities_track_redmine_gtt_presence
    # redmine_gtt is a hard dependency (init.rb requires it), so in a correctly
    # assembled instance it is present and the base geo surface is available.
    assert Redmine::Plugin.installed?(:redmine_gtt), 'test setup expects redmine_gtt installed'
    assert @report[:requires][:redmine_gtt]
    %i[geojson_read geojson_write spatial_filter_bbox spatial_filter_distance].each do |cap|
      assert_equal true, @report[:capabilities][cap], "#{cap} should be advertised when redmine_gtt is present"
    end
  end

  def test_base_capabilities_are_false_without_redmine_gtt
    # Detection is real, not hardcoded: with redmine_gtt absent the base surface
    # is reported unavailable.
    Redmine::Plugin.stub(:installed?, false) do
      report = RedmineGttSync::Capabilities.report
      refute report[:requires][:redmine_gtt]
      assert_equal false, report[:capabilities][:geojson_read]
    end
  end

  def test_contract_capabilities_reflect_defined_routes
    # None of the contract endpoints are routed yet, so all report false. This
    # is route-driven, not a hardcoded flag: defining a capability's route flips
    # it on without touching the reporter.
    RedmineGttSync::Capabilities::CONTRACT_ROUTES.each do |cap, route_name|
      expected = Rails.application.routes.named_routes.key?(route_name)
      assert_equal expected, @report[:capabilities][cap]
    end
    refute @report[:capabilities][:bulk_geometry_write]
  end

  def test_capabilities_probe_route_is_defined
    assert Rails.application.routes.named_routes.key?(:gtt_sync_capabilities)
  end
end
