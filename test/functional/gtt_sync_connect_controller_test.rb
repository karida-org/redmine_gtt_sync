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

  test 'shows connection details to a user with gtt_sync access' do
    @request.session[:user_id] = 1 # admin passes the permission gate
    get :show
    assert_response :success
    assert_select 'h2', 'Connect QGIS'
    # The click-to-copy wiring must render: the page script plus a Copy button
    # per value. With no client_id advertised the client-id row is omitted, so
    # only URL + Scopes carry a button.
    assert_select 'script[src*=?]', 'gtt_sync_connect'
    assert_select 'button.gtt-copy', 2
    assert_select 'th', text: 'OAuth Client ID', count: 0
  end

  test 'shows a copy button for the client id when one is advertised' do
    app = RedmineGttSync::OAuth.ensure_qtask_application
    Setting.plugin_redmine_gtt_sync = { 'oauth_application_uid' => app.uid }
    @request.session[:user_id] = 1
    get :show
    assert_response :success
    # Client-id row now present: URL + Client ID + Scopes = three Copy buttons.
    assert_select 'th', text: 'OAuth Client ID'
    assert_select 'button.gtt-copy', 3
    assert_select 'code.gtt-copy-value', text: app.uid
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
