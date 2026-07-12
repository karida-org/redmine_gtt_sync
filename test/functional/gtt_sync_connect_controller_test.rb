require_relative '../test_helper'
require_relative '../../app/controllers/gtt_sync_connect_controller'

# The user-facing Connect QGIS page: login required, shows details to any
# logged-in user, and serves the QGIS config only when a client_id is advertised.
class GttSyncConnectControllerTest < ActionController::TestCase
  fixtures :users, :email_addresses

  def teardown
    Setting.plugin_redmine_gtt_sync = { 'oauth_application_uid' => '' }
    Doorkeeper::Application.where(name: RedmineGttSync::OAuth::QTASK_APP_NAME).destroy_all
  end

  test 'requires login' do
    get :show
    assert_response :redirect
  end

  test 'forbids a logged-in user without gtt_sync access' do
    @request.session[:user_id] = 2 # jsmith holds no use_gtt_sync permission
    get :show
    assert_response :forbidden
  end

  test 'no client_id: an admin sees the settings link and no details table' do
    @request.session[:user_id] = 1 # admin passes the permission gate
    get :show
    assert_response :success
    assert_select 'h2', 'Connect QGIS'
    # Nothing to connect with yet, so the details table and its Copy buttons are
    # withheld; the admin gets an actionable link to the plugin settings instead.
    assert_select 'button.gtt-copy', 0
    assert_select 'table.list', 0
    assert_select 'a[href=?]', plugin_settings_path(id: 'redmine_gtt_sync')
    # The QGIS-config download and setup instructions are premature too.
    assert_select 'a[href=?]', gtt_sync_connect_qgis_config_path, count: 0
    assert_select 'p.info', 0
  end

  test 'no client_id: a non-admin is told to ask an administrator' do
    # jsmith is a member of project 1 via role 1; grant that role use_gtt_sync so
    # he clears the access gate but is still a non-admin viewer.
    Role.find(1).add_permission!(:use_gtt_sync)
    @request.session[:user_id] = 2
    get :show
    assert_response :success
    # No details table, no settings link, and no admin-only actionable copy.
    assert_select 'table.list', 0
    assert_select 'a[href=?]', plugin_settings_path(id: 'redmine_gtt_sync'), count: 0
    assert_select 'p.warning'
    # Same for a non-admin: no download link and no setup instructions.
    assert_select 'a[href=?]', gtt_sync_connect_qgis_config_path, count: 0
    assert_select 'p.info', 0
  end

  test 'shows a copy button for the client id when one is advertised' do
    app = RedmineGttSync::OAuth.ensure_qtask_application
    Setting.plugin_redmine_gtt_sync = { 'oauth_application_uid' => app.uid }
    @request.session[:user_id] = 1
    get :show
    assert_response :success
    # The click-to-copy wiring must render: the page script plus a Copy button
    # per value. Client-id row now present: URL + Client ID + Scopes = three.
    assert_select 'script[src*=?]', 'gtt_sync_connect'
    assert_select 'th', text: 'OAuth Client ID'
    assert_select 'button.gtt-copy', 3
    assert_select 'code.gtt-copy-value', text: app.uid
    # With a client_id the download link and setup instructions are offered.
    assert_select 'a[href=?]', gtt_sync_connect_qgis_config_path
    assert_select 'p.info'
  end

  test 'qgis_config downloads the config when a client_id is advertised' do
    app = RedmineGttSync::OAuth.ensure_qtask_application
    Setting.plugin_redmine_gtt_sync = { 'oauth_application_uid' => app.uid }
    @request.session[:user_id] = 1
    get :qgis_config
    assert_response :success
    assert_equal 'application/json', @response.media_type
    body = JSON.parse(@response.body)
    assert_equal app.uid, body['clientId']
    assert_equal 3, body['grantFlow'] # Authorization Code + PKCE
  end

  test 'qgis_config 404s when no client_id is advertised' do
    @request.session[:user_id] = 1
    get :qgis_config
    assert_response :not_found
  end

  test 'qgis_config requires login' do
    # Guard the download endpoint too: it must never be publicly accessible.
    get :qgis_config
    assert_response :redirect
  end

  test 'qgis_config forbids a logged-in user without gtt_sync access' do
    @request.session[:user_id] = 2 # jsmith holds no use_gtt_sync permission
    get :qgis_config
    assert_response :forbidden
  end
end
