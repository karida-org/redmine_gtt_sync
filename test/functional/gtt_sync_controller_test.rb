# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../app/controllers/gtt_sync_controller'

# End-to-end coverage of the controller: id-vs-identifier resolution, the 404
# (visibility) path, and the governance gate (gtt_sync module + use_gtt_sync).
class GttSyncControllerTest < ActionController::TestCase
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles,
           :enabled_modules, :trackers, :issue_statuses, :issues,
           :journals, :journal_details

  setup do
    # Governance opt-in: enable the module on project 1 so access is allowed
    # for a permitted user (admin holds every permission). Tests that assert the
    # gate itself override this.
    project = Project.find(1)
    project.enabled_module_names = project.enabled_module_names | ['gtt_sync']
  end

  def issue_count(json)
    geometry = %w[point line polygon].sum do |kind|
      json['issues'][kind]['features'].size
    end
    geometry + json['issues']['unplaced'].size
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

  test 'project_bundle applies an optional query filter within the project' do
    @request.session[:user_id] = 1
    get :project_bundle, params: { id: 'ecookbook' }
    assert_operator issue_count(JSON.parse(response.body)), :>, 0

    # A query whose filter matches nothing, run in the project's context, must
    # narrow the bundle to zero - proving the query_id is actually applied.
    query = IssueQuery.new(
      name: 'no match', user: User.find(1), visibility: Query::VISIBILITY_PUBLIC
    )
    query.add_filter('subject', '~', ['zzz-no-such-subject-zzz'])
    query.save!
    get :project_bundle, params: { id: 'ecookbook', query_id: query.id }
    assert_response :success
    assert_equal 0, issue_count(JSON.parse(response.body))
  end

  test 'project_bundle with an unknown query is 404' do
    @request.session[:user_id] = 1
    get :project_bundle, params: { id: 'ecookbook', query_id: 999_999 }
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

  test 'issue document carries the rich sections' do
    @request.session[:user_id] = 1
    get :issue, params: { id: 1 }
    assert_response :success
    doc = JSON.parse(response.body)
    # The canonical data model always exposes these sections (possibly empty).
    assert doc.key?('journals')
    assert doc.key?('relations')
    assert doc.key?('changesets')
    assert doc.key?('attachments')
    assert doc.key?('custom_fields')
    # RBAC editing contract: writable fields + valid status transitions.
    assert_includes doc['editable']['fields'], 'subject'
    assert_includes doc['editable']['fields'], 'status_id'
    assert doc['editable']['status_transitions'].any?
    # Issue 1 has journals in the fixtures, with change details.
    assert doc['journals'].any?, 'expected journals from fixtures'
    assert(doc['journals'].any? { |j| j['details'].any? })
  end

  test 'issue is forbidden without integration access' do
    # Issue 1 is in project 1; the user can view it, but with the module
    # disabled the integration gate returns 403.
    project = Project.find(1)
    project.enabled_module_names = project.enabled_module_names - ['gtt_sync']
    @request.session[:user_id] = 1
    get :issue, params: { id: 1 }
    assert_response :forbidden
  end
end
