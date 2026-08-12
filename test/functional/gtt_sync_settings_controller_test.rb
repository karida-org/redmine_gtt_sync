# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../app/controllers/gtt_sync_settings_controller'

# The admin-only provisioning endpoint: non-admins blocked, admins provision +
# select the QTask app and land back on the plugin settings screen.
class GttSyncSettingsControllerTest < ActionController::TestCase
  fixtures :users, :email_addresses

  def teardown
    Setting.plugin_redmine_gtt_sync = {
      'oauth_application_uid' => '',
      'oauth_mobile_application_uid' => ''
    }
    Doorkeeper::Application.where(
      name: [RedmineGttSync::OAuth::QTASK_APP_NAME,
             RedmineGttSync::OAuth::MOBILE_APP_NAME]
    ).destroy_all
  end

  test 'anonymous is redirected to login' do
    post :create_oauth_application
    assert_response :redirect
  end

  test 'non-admin is forbidden' do
    @request.session[:user_id] = 2 # jsmith, not an admin
    post :create_oauth_application
    assert_response :forbidden
  end

  test 'admin provisions, selects, and redirects back to settings' do
    @request.session[:user_id] = 1 # admin
    post :create_oauth_application

    assert_redirected_to plugin_settings_path(id: 'redmine_gtt_sync')
    assert flash[:notice].present?
    public_apps = Doorkeeper::Application.where(confidential: false)
    app = public_apps.find_by(name: RedmineGttSync::OAuth::QTASK_APP_NAME)
    assert app, 'expected a public QTask application to exist'
    assert_equal app.uid, Setting.plugin_redmine_gtt_sync['oauth_application_uid']
  end

  test 'non-admin cannot provision the mobile application' do
    @request.session[:user_id] = 2 # jsmith, not an admin
    post :create_mobile_oauth_application
    assert_response :forbidden
  end

  test 'admin provisions and selects the mobile application' do
    @request.session[:user_id] = 1 # admin
    post :create_mobile_oauth_application

    assert_redirected_to plugin_settings_path(id: 'redmine_gtt_sync')
    assert flash[:notice].present?
    app = Doorkeeper::Application.where(confidential: false)
                                 .find_by(name: RedmineGttSync::OAuth::MOBILE_APP_NAME)
    assert app, 'expected a public Georeport application to exist'
    assert_equal RedmineGttSync::OAuth::MOBILE_REDIRECT_URI, app.redirect_uri
    assert_equal app.uid,
                 Setting.plugin_redmine_gtt_sync['oauth_mobile_application_uid']
    # Provisioning the mobile app must not touch the desktop selection.
    assert_equal '', Setting.plugin_redmine_gtt_sync['oauth_application_uid'].to_s
  end
end
