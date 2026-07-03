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

  test 'shows connection details to a logged-in non-admin' do
    @request.session[:user_id] = 2 # jsmith
    get :show
    assert_response :success
    assert_select 'h2', 'Connect QGIS'
  end

  test 'qgis_config downloads the config when a client_id is advertised' do
    app = RedmineGttSync::OAuth.ensure_qtask_application
    Setting.plugin_redmine_gtt_sync = { 'oauth_application_uid' => app.uid }
    @request.session[:user_id] = 2
    get :qgis_config
    assert_response :success
    assert_equal 'application/json', @response.media_type
    body = JSON.parse(@response.body)
    assert_equal app.uid, body['clientId']
    assert_equal 3, body['grantFlow'] # Authorization Code + PKCE
  end

  test 'qgis_config 404s when no client_id is advertised' do
    @request.session[:user_id] = 2
    get :qgis_config
    assert_response :not_found
  end
end
