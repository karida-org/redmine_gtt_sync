# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../app/controllers/gtt_sync_controller'

# The time-entry contract (issue #89): logging time on an issue through
# safe_attributes and Redmine's :log_time gate, the own-entries index, the
# schema section, the issue document's can_log_time flag, and the capability
# flags. Permissions are the real Redmine RBAC (no stubs).
#
# Fixture cast: project 1 (eCookbook, public), user 2 (jsmith, member via
# role 1), issue 1 (project 1), activities from the enumerations fixture.
class GttSyncTimeEntriesTest < ActionController::TestCase
  tests GttSyncController

  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles,
           :enabled_modules, :trackers, :projects_trackers, :issue_statuses,
           :issues, :enumerations, :time_entries, :workflows

  setup do
    project = Project.find(1)
    project.enabled_module_names = project.enabled_module_names | ['gtt_sync']
    @request.session[:user_id] = 2 # jsmith, member of project 1 via role 1
  end

  def grant(*permissions)
    Role.find(1).update!(
      permissions: %i[view_issues use_gtt_sync] + permissions
    )
    User.current = nil # drop Redmine's per-request permission memoization
  end

  def activity_id
    TimeEntryActivity.active.first.id
  end

  # --- create ---

  test 'logs time on an issue as the authenticated user' do
    grant(:log_time)
    assert_difference 'TimeEntry.count', 1 do
      post :create_time_entry, params: {
        id: 1, hours: 1.5, activity_id: activity_id,
        spent_on: '2026-08-10', comments: 'Fence repaired'
      }
    end
    assert_response :created

    json = JSON.parse(response.body)
    entry = TimeEntry.find(json['id'])
    assert_equal 2, entry.user_id
    assert_equal 2, entry.author_id
    assert_equal 1, entry.issue_id
    assert_in_delta 1.5, entry.hours
    assert_equal Date.new(2026, 8, 10), entry.spent_on
    assert_equal 'Fence repaired', json['comments']
    assert_equal 1.5, json['hours']
    assert_equal 'Fence repaired', entry.comments
  end

  test 'accepts a nested time_entry payload too' do
    grant(:log_time)
    post :create_time_entry, params: {
      id: 1, time_entry: { hours: 2, activity_id: activity_id }
    }
    assert_response :created
  end

  test 'spent_on defaults to today' do
    grant(:log_time)
    post :create_time_entry, params: { id: 1, hours: 1, activity_id: activity_id }
    assert_response :created
    assert_equal User.find(2).today,
                 TimeEntry.find(JSON.parse(response.body)['id']).spent_on
  end

  test 'never logs time as someone else, whatever the payload says' do
    grant(:log_time, :log_time_for_other_users)
    post :create_time_entry, params: {
      id: 1, hours: 1, activity_id: activity_id, user_id: 3
    }
    assert_response :created
    assert_equal 2, TimeEntry.find(JSON.parse(response.body)['id']).user_id
  end

  test 'refuses without the log_time permission' do
    grant # view_issues + use_gtt_sync only
    assert_no_difference 'TimeEntry.count' do
      post :create_time_entry, params: { id: 1, hours: 1, activity_id: activity_id }
    end
    assert_response :forbidden
  end

  test 'a validation failure reports the server messages' do
    grant(:log_time)
    post :create_time_entry, params: { id: 1, comments: 'no hours' }
    assert_response :unprocessable_entity
    assert JSON.parse(response.body)['errors'].any?
  end

  test 'a missing issue is a 404' do
    grant(:log_time)
    post :create_time_entry, params: { id: 999_999, hours: 1 }
    assert_response :not_found
  end

  # --- index ---

  test 'lists only the callers own entries with range totals' do
    grant(:log_time, :view_time_entries)
    TimeEntry.create!(project: Project.find(1), issue: Issue.find(1),
                      user: User.find(2), author: User.find(2),
                      hours: 2.0, spent_on: Date.new(2026, 8, 10),
                      activity_id: activity_id)
    TimeEntry.create!(project: Project.find(1), issue: Issue.find(1),
                      user: User.find(3), author: User.find(3),
                      hours: 5.0, spent_on: Date.new(2026, 8, 10),
                      activity_id: activity_id)

    get :time_entries, params: { from: '2026-08-01', to: '2026-08-31' }
    assert_response :success
    json = JSON.parse(response.body)

    assert_equal 1, json['total_count']
    assert_in_delta 2.0, json['total_hours']
    entry = json['time_entries'].sole
    assert_equal 2.0, entry['hours']
    assert_equal '2026-08-10', entry['spent_on']
    assert_equal 1, entry['issue']['id']
    assert entry['activity']['name'].present?
  end

  test 'the date range filters by spent_on' do
    grant(:log_time, :view_time_entries)
    TimeEntry.create!(project: Project.find(1), user: User.find(2),
                      author: User.find(2), hours: 1,
                      spent_on: Date.new(2026, 7, 1), activity_id: activity_id)

    get :time_entries, params: { from: '2026-08-01' }
    assert_response :success
    assert_equal 0, JSON.parse(response.body)['total_count']
  end

  test 'a malformed date is a 400, not a silent full-range query' do
    grant(:view_time_entries)
    get :time_entries, params: { from: 'yesterday' }
    assert_response :bad_request
  end

  test 'a foreign user_id is refused rather than reinterpreted' do
    grant(:view_time_entries)
    get :time_entries, params: { user_id: 3 }
    assert_response :bad_request
  end

  test 'user_id=me is accepted' do
    grant(:view_time_entries)
    get :time_entries, params: { user_id: 'me' }
    assert_response :success
  end

  test 'entries outside gtt_sync projects stay out of the index' do
    grant(:log_time, :view_time_entries)
    # Log in project 1, then disable its gtt_sync module: the entry must
    # vanish from the contract's scope.
    TimeEntry.create!(project: Project.find(1), user: User.find(2),
                      author: User.find(2), hours: 3,
                      spent_on: Date.new(2026, 8, 10), activity_id: activity_id)
    project = Project.find(1)
    project.enabled_module_names = project.enabled_module_names - ['gtt_sync']

    get :time_entries, params: {}
    assert_response :success
    assert_equal 0, JSON.parse(response.body)['total_count']
  end

  test 'totals cover the whole scope even when the list is capped' do
    grant(:log_time, :view_time_entries)
    limit = GttSyncController::TIME_ENTRIES_LIMIT
    base = {
      project_id: 1, user_id: 2, author_id: 2, hours: 1.0,
      spent_on: Date.new(2026, 8, 10), activity_id: activity_id,
      tyear: 2026, tmonth: 8, tweek: Date.new(2026, 8, 10).cweek,
      created_on: Time.current, updated_on: Time.current
    }
    TimeEntry.insert_all(Array.new(limit + 1) { base })

    get :time_entries, params: { from: '2026-08-01' }
    assert_response :success
    json = JSON.parse(response.body)

    assert_equal limit, json['time_entries'].size
    assert_equal limit + 1, json['total_count']
    assert_in_delta limit + 1, json['total_hours']
  end

  test 'project_id narrows the scope' do
    grant(:log_time, :view_time_entries)
    TimeEntry.create!(project: Project.find(1), user: User.find(2),
                      author: User.find(2), hours: 1,
                      spent_on: Date.new(2026, 8, 10), activity_id: activity_id)

    get :time_entries, params: { project_id: 1, from: '2026-08-01' }
    assert_response :success
    assert_equal 1, JSON.parse(response.body)['total_count']
  end

  test 'project_id without the integration is a 403' do
    grant(:view_time_entries)
    get :time_entries, params: { project_id: 3 } # module never enabled
    assert_response :forbidden
  end

  test 'issue_id narrows the scope' do
    grant(:log_time, :view_time_entries)
    TimeEntry.create!(project: Project.find(1), issue: Issue.find(1),
                      user: User.find(2), author: User.find(2), hours: 1,
                      spent_on: Date.new(2026, 8, 10), activity_id: activity_id)
    TimeEntry.create!(project: Project.find(1), issue: Issue.find(2),
                      user: User.find(2), author: User.find(2), hours: 2,
                      spent_on: Date.new(2026, 8, 10), activity_id: activity_id)

    get :time_entries, params: { issue_id: 1, from: '2026-08-01' }
    assert_response :success
    json = JSON.parse(response.body)
    assert_equal 1, json['total_count']
    assert_equal 1, json['time_entries'].sole['issue']['id']
  end

  test 'the unscoped index needs view_issues, matching the project branch' do
    # view_time_entries + use_gtt_sync, but NOT view_issues: entries carry
    # issue subjects, so both branches must refuse issue data consistently.
    Role.find(1).update!(permissions: %i[use_gtt_sync view_time_entries log_time])
    User.current = nil
    TimeEntry.create!(project: Project.find(1), issue: Issue.find(1),
                      user: User.find(2), author: User.find(2), hours: 1,
                      spent_on: Date.new(2026, 8, 10), activity_id: activity_id)

    get :time_entries, params: {}
    assert_response :success
    assert_equal 0, JSON.parse(response.body)['total_count']
  end

  # --- schema, document, capabilities ---

  test 'the project schema advertises the time-entry section' do
    grant(:log_time)
    get :project_schema, params: { id: 1 }
    assert_response :success
    section = JSON.parse(response.body)['time_entry']

    assert_equal true, section['can_log_time']
    assert section['activities'].any?
    assert(section['activities'].all? { |a| a['id'] && a['name'] })
    assert_includes section['writable'], 'hours'
    assert_includes section['writable'], 'activity_id'
  end

  test 'the schema reports can_log_time false without the permission' do
    grant
    get :project_schema, params: { id: 1 }
    assert_response :success
    assert_equal false, JSON.parse(response.body)['time_entry']['can_log_time']
  end

  test 'the issue document advertises can_log_time' do
    grant(:log_time)
    get :issue, params: { id: 1 }
    assert_response :success
    assert_equal true, JSON.parse(response.body)['editable']['can_log_time']

    grant
    get :issue, params: { id: 1 }
    assert_equal false, JSON.parse(response.body)['editable']['can_log_time']
  end

  test 'the capabilities probe advertises the time-entry endpoints' do
    get :capabilities
    assert_response :success
    capabilities = JSON.parse(response.body)['capabilities']
    assert_equal true, capabilities['time_entries']
    assert_equal true, capabilities['time_entry_create']
  end
end
