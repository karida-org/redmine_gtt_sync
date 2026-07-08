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

  def test_base_capabilities_are_gated_on_redmine_gtt_presence
    # Detection is real, not hardcoded: the base geo surface is advertised only
    # when redmine_gtt is present. Exercise the gate directly (both branches)
    # rather than stubbing global plugin state.
    base_keys = %i[geojson_read geojson_write spatial_filter_bbox spatial_filter_distance]
    present = RedmineGttSync::Capabilities.base_capabilities(true)
    absent  = RedmineGttSync::Capabilities.base_capabilities(false)
    base_keys.each do |cap|
      assert_equal true, present[cap], "#{cap} available when redmine_gtt present"
      assert_equal false, absent[cap], "#{cap} unavailable when redmine_gtt absent"
    end
  end

  def test_report_advertises_base_surface_since_redmine_gtt_is_a_dependency
    # redmine_gtt is a hard dependency (init.rb requires it), so a correctly
    # assembled instance has it and the report reflects that.
    assert Redmine::Plugin.installed?(:redmine_gtt), 'test setup expects redmine_gtt installed'
    assert @report[:requires][:redmine_gtt]
    assert_equal true, @report[:capabilities][:geojson_read]
  end

  def test_reports_the_installed_redmine_gtt_version
    # Not just presence: clients may need to know which redmine_gtt release runs.
    assert_equal Redmine::Plugin.find(:redmine_gtt).version.to_s,
                 @report[:requires][:redmine_gtt_version]
  end

  def test_contract_capabilities_reflect_defined_routes
    # Route-driven, not a hardcoded flag: a contract capability is advertised
    # only when its route exists. None are implemented yet, so all report false.
    RedmineGttSync::Capabilities::CONTRACT_ROUTES.each do |cap, route_name|
      expected = RedmineGttSync::Capabilities.route_defined?(route_name)
      assert_equal expected, @report[:capabilities][cap]
    end
    refute @report[:capabilities][:bulk_geometry_write]
    # issue_jsonld, project_bundle, and query_bundle have routes -> advertise true.
    assert @report[:capabilities][:issue_jsonld]
    assert @report[:capabilities][:project_bundle]
    assert @report[:capabilities][:query_bundle]
  end

  def test_report_advertises_query_scoped_bundle_behavior
    # A behaviour of existing routes (optional query_id + all-projects scope),
    # not a new route, so it's a flag a client feature-detects before passing
    # query_id (an older server would silently ignore it).
    assert_equal true, @report[:capabilities][:query_scoped_bundle]
  end

  def test_capabilities_probe_route_is_detected
    # Sanity-check the detection predicate against a route that does exist.
    assert RedmineGttSync::Capabilities.route_defined?(:gtt_sync_capabilities)
  end

  def test_advertises_oauth_scopes_and_endpoints
    # A client (QTask) reads these off the public probe to build its OAuth2
    # config without the user knowing the scopes. Endpoints come from Setting.
    oauth = @report[:oauth]
    base = "#{Setting.protocol}://#{Setting.host_name}"
    assert_equal "#{base}/oauth/authorize", oauth[:authorize_url]
    assert_equal "#{base}/oauth/token", oauth[:token_url]
    assert_equal RedmineGttSync::OAuth::SCOPES, oauth[:scopes]
    # The integration gate scope must be advertised, else a scoped token 403s.
    assert_includes oauth[:scopes], 'use_gtt_sync'
    assert_includes oauth[:scopes], 'view_issues'
    # Note scopes: over OAuth these gate note features even for an admin, so a
    # scoped token can otherwise only save public notes.
    assert_includes oauth[:scopes], 'add_issue_notes'
    assert_includes oauth[:scopes], 'view_private_notes'
    assert_includes oauth[:scopes], 'set_notes_private'
    # The issue Private flag (is_private) is scope-gated the same way.
    assert_includes oauth[:scopes], 'set_issues_private'
    # Destructive/edit actions (epic karida-org/qtask#167): delete an issue, and
    # edit or clear (= delete) a note. All three are real Redmine permissions.
    assert_includes oauth[:scopes], 'delete_issues'
    assert_includes oauth[:scopes], 'edit_issue_notes'
    assert_includes oauth[:scopes], 'edit_own_issue_notes'
  end

  def test_oauth_advertisement_omits_client_secret_and_id_by_default
    # Public probe: never leak a client secret, and no client_id until an admin
    # selects an application to advertise (default is unset).
    oauth = @report[:oauth]
    refute oauth.key?(:client_secret)
    refute oauth.key?(:client_id)
  end

  def test_advertises_selected_public_apps_client_id
    app = Doorkeeper::Application.create!(
      name: 'QTaskTest', redirect_uri: 'http://127.0.0.1:7070/',
      scopes: RedmineGttSync::OAuth::SCOPES.join(' '), confidential: false
    )
    with_gtt_sync_oauth_app(app.uid) do
      assert_equal app.uid, RedmineGttSync::Capabilities.report[:oauth][:client_id]
    end
  ensure
    app&.destroy
  end

  def test_never_advertises_a_confidential_apps_client_id
    # A confidential client_id must never be published, even if selected.
    app = Doorkeeper::Application.create!(
      name: 'QTaskConfidential', redirect_uri: 'http://127.0.0.1:7070/',
      scopes: RedmineGttSync::OAuth::SCOPES.join(' '), confidential: true
    )
    with_gtt_sync_oauth_app(app.uid) do
      refute RedmineGttSync::Capabilities.report[:oauth].key?(:client_id)
    end
  ensure
    app&.destroy
  end

  def test_stale_selected_uid_advertises_nothing
    # A selected uid that no longer resolves to a public app leaks nothing.
    with_gtt_sync_oauth_app('does-not-exist') do
      refute RedmineGttSync::Capabilities.report[:oauth].key?(:client_id)
    end
  end

  private

  def with_gtt_sync_oauth_app(uid)
    previous = Setting.plugin_redmine_gtt_sync
    Setting.plugin_redmine_gtt_sync = previous.merge('oauth_application_uid' => uid)
    yield
  ensure
    Setting.plugin_redmine_gtt_sync = previous
  end
end
