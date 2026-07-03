require_relative '../test_helper'
require_relative '../../app/controllers/gtt_sync_controller'

# The query-driven bundle endpoint: query_id required, correct payload shape,
# and the per-project use_gtt_sync gate layered on the query's own visibility.
class GttSyncQueryBundleTest < ActionController::TestCase
  tests GttSyncController

  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles,
           :enabled_modules, :trackers, :issue_statuses, :issues

  setup do
    # A public, global query (no project filter) visible to every user.
    @query = IssueQuery.create!(
      name: 'QTask all', user: User.find(1), visibility: Query::VISIBILITY_PUBLIC
    )
  end

  def issue_count(json)
    geometry = %w[point line polygon].sum do |kind|
      json['issues'][kind]['features'].size
    end
    geometry + json['issues']['unplaced'].size
  end

  test 'query_id is required' do
    @request.session[:user_id] = 1
    get :query_bundle
    assert_response :bad_request
  end

  test 'unknown query is 404' do
    @request.session[:user_id] = 1
    get :query_bundle, params: { query_id: 999_999 }
    assert_response :not_found
  end

  test 'returns the bundle shape' do
    @request.session[:user_id] = 1 # admin holds use_gtt_sync everywhere
    get :query_bundle, params: { query_id: @query.id }
    assert_response :success
    json = JSON.parse(response.body)
    assert json['issues'].key?('point')
    assert json['issues'].key?('unplaced')
    assert json.key?('project_boundary')
    assert_equal 'FeatureCollection', json['project_boundary']['type']
    assert json.key?('projects')
  end

  test 'filters out issues in projects without use_gtt_sync' do
    # jsmith can view issues in his projects but holds no use_gtt_sync anywhere,
    # so the query returns issues yet the bundle excludes them all.
    @request.session[:user_id] = 2
    get :query_bundle, params: { query_id: @query.id }
    assert_response :success
    assert_equal 0, issue_count(JSON.parse(response.body))
  end

  test 'includes issues in projects where the user holds use_gtt_sync' do
    Role.find(1).add_permission!(:use_gtt_sync)
    project = Project.find(1)
    project.enabled_module_names = project.enabled_module_names | ['gtt_sync']
    @request.session[:user_id] = 2 # jsmith is a member of project 1 via role 1

    get :query_bundle, params: { query_id: @query.id }
    assert_response :success
    assert_operator issue_count(JSON.parse(response.body)), :>, 0
  end
end
