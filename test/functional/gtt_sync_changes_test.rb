# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../app/controllers/gtt_sync_controller'

# The change-feed endpoint: cursor validation, permission scoping (visibility +
# the per-project use_gtt_sync gate), the project_id variant, deletion
# reconciliation via known_ids, and the geometry-write timestamp assumption
# the whole feed depends on.
class GttSyncChangesTest < ActionController::TestCase
  tests GttSyncController

  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles,
           :enabled_modules, :trackers, :issue_statuses, :issues, :enumerations

  EPOCH = '2000-01-01T00:00:00Z'

  setup do
    project = Project.find(1)
    project.enabled_module_names = project.enabled_module_names | ['gtt_sync']
    @request.session[:user_id] = 1
  end

  teardown do
    User.current = nil
  end

  # Assign geometry the way the API does, as an explicit user: outside a
  # request cycle User.current is anonymous, and safe_attributes would
  # silently drop the geojson attribute.
  def place_issue(issue)
    User.current = User.find(1)
    issue.safe_attributes = {
      'geojson' => '{"type":"Feature","geometry":{"type":"Point",' \
                   '"coordinates":[135.3575,34.7472]}}'
    }
    issue.save!
  end

  def feed(params = {})
    get :changes, params: { since: EPOCH }.merge(params)
    assert_response :success
    JSON.parse(response.body)
  end

  test 'requires a since cursor' do
    get :changes
    assert_response :bad_request
    get :changes, params: { since: 'not-a-time' }
    assert_response :bad_request
  end

  test 'returns settled changes after the cursor with a follow-up token' do
    body = feed
    ids = body['issues'].map { |i| i['id'] }
    assert_includes ids, 1 # project 1 fixture issue, updated long ago
    assert body.key?('next_since')
    assert_equal false, body['more']

    # Polling again from the returned token yields nothing new.
    again = feed(since: body['next_since'])
    assert_equal [], again['issues']
    assert_equal body['next_since'], again['next_since']
  end

  test 'only projects with the integration are in the default scope' do
    # Issue 4 lives in project 2, which never enabled the gtt_sync module.
    ids = feed['issues'].map { |i| i['id'] }
    assert_not_includes ids, 4
  end

  test 'issue visibility is enforced for a plain member' do
    Role.find(1).add_permission!(:use_gtt_sync)
    @request.session[:user_id] = 2 # jsmith, member of project 1 via role 1
    ids = feed['issues'].map { |i| i['id'] }
    assert_includes ids, 1
    assert_not_includes ids, 4
  end

  test 'project_id narrows the feed to one project' do
    ids = feed(project_id: 'ecookbook')['issues'].map { |i| i['id'] }
    assert ids.any?
    assert(Issue.where(id: ids).all? { |i| i.project_id == 1 })
  end

  test 'project_id is gated like the bundles' do
    project = Project.find(1)
    project.enabled_module_names = project.enabled_module_names - ['gtt_sync']
    get :changes, params: { since: EPOCH, project_id: 'ecookbook' }
    assert_response :forbidden
    get :changes, params: { since: EPOCH, project_id: 'no-such-project' }
    assert_response :not_found
  end

  test 'known_ids lists the reconciliation set for the same scope' do
    body = feed(known_ids: '1')
    assert_includes body['known_ids'], 1
    assert_not_includes body['known_ids'], 4 # project 2: no integration

    scoped = feed(known_ids: '1', project_id: 'ecookbook')
    assert_equal Issue.visible.where(project_id: 1).order(:id).ids,
                 scoped['known_ids']
  end

  test 'known_ids is a strict opt-in: 0 and junk stay off' do
    # Only the documented truthy forms enable the (large) id list, so a
    # sloppy known_ids=0 cannot amplify the payload by accident.
    assert_not feed(known_ids: '0').key?('known_ids')
    assert_not feed(known_ids: 'no').key?('known_ids')
    assert feed(known_ids: 'true').key?('known_ids')
  end

  test 'a geometry-only save bumps updated_on so the feed can see it' do
    # The feed keys on updated_on, so this pins the redmine_gtt behavior it
    # depends on: writing the geojson safe-attribute is a normal attribute
    # assignment and must touch the timestamp like any other edit.
    issue = Issue.find(1)
    issue.update_column(:updated_on, 2.days.ago)
    before = issue.reload.updated_on

    place_issue(issue)
    assert_operator issue.reload.updated_on, :>, before
  end

  test 'a placed issue carries its geometry in the feed entry' do
    issue = Issue.find(1)
    place_issue(issue)
    issue.update_column(:updated_on, 1.hour.ago) # settle past the lag

    entry = feed['issues'].find { |i| i['id'] == 1 }
    assert entry, 'issue 1 expected in the feed'
    assert_equal 'Point', entry['geometry']['type']
  end

  test 'capabilities advertises the change feed now that its route exists' do
    assert_equal true,
                 RedmineGttSync::Capabilities.report[:capabilities][:change_feed]
  end
end
