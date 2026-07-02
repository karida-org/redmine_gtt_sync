require_relative '../test_helper'
require_relative '../../app/controllers/gtt_sync_controller'

# End-to-end coverage of the controller: id-vs-identifier resolution, the 404
# (visibility) path, and the governance gate (gtt_sync module + use_gtt_sync).
class GttSyncControllerTest < ActionController::TestCase
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles,
           :enabled_modules, :trackers, :issue_statuses, :issues

  setup do
    # Governance opt-in: enable the module on project 1 so access is allowed
    # for a permitted user (admin holds every permission). Tests that assert the
    # gate itself override this.
    project = Project.find(1)
    project.enabled_module_names = project.enabled_module_names | ['gtt_sync']
  end

  test 'resolves a project by identifier' do
    @request.session[:user_id] = 1
    get :project_bundle, params: { id: 'ecookbook' }
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 'ecookbook', body['project']['identifier']
    assert body['issues'].key?('unplaced')
  end

  test 'resolves a project by numeric id' do
    @request.session[:user_id] = 1
    get :project_bundle, params: { id: '1' }
    assert_response :success
    assert_equal 1, JSON.parse(response.body)['project']['id']
  end

  test 'unknown project returns 404' do
    @request.session[:user_id] = 1
    get :project_bundle, params: { id: 'no-such-project' }
    assert_response :not_found
  end

  test 'project the user cannot see returns 404 (visibility is enforced)' do
    # Private project; an anonymous request must not see it (login not required
    # so it is the visibility 404, not a login redirect).
    Project.find(1).update_column(:is_public, false)
    with_settings login_required: '0' do
      get :project_bundle, params: { id: 'ecookbook' }
    end
    assert_response :not_found
  end

  test 'forbidden when the gtt_sync module is disabled' do
    project = Project.find(1)
    project.enabled_module_names = project.enabled_module_names - ['gtt_sync']
    @request.session[:user_id] = 1
    get :project_bundle, params: { id: 'ecookbook' }
    assert_response :forbidden
  end

  test 'forbidden when the user role lacks use_gtt_sync' do
    # jsmith (member of ecookbook) can see the project and its issues, but no
    # role has the new use_gtt_sync permission, so integration access is denied
    # even with the module enabled.
    @request.session[:user_id] = 2
    get :project_bundle, params: { id: 'ecookbook' }
    assert_response :forbidden
  end

  test 'schema exposes trackers, statuses, custom fields, and writable fields' do
    field = IssueCustomField.create!(
      name: 'Severity', field_format: 'list',
      possible_values: %w[Low Medium High], is_for_all: true
    )
    field.trackers = Tracker.all

    @request.session[:user_id] = 1
    get :project_schema, params: { id: 'ecookbook' }
    assert_response :success
    body = JSON.parse(response.body)
    assert body['trackers'].any?
    assert body['statuses'].any?
    assert_includes body['writable'], 'subject'
    assert_includes body['writable'], 'geojson'
    assert(body['custom_fields'].any? { |cf| cf['name'] == 'Severity' })
  end

  test 'schema returns 404 for an unknown project' do
    @request.session[:user_id] = 1
    get :project_schema, params: { id: 'no-such-project' }
    assert_response :not_found
  end

  test 'schema is forbidden without integration access' do
    project = Project.find(1)
    project.enabled_module_names = project.enabled_module_names - ['gtt_sync']
    @request.session[:user_id] = 1
    get :project_schema, params: { id: 'ecookbook' }
    assert_response :forbidden
  end
end
