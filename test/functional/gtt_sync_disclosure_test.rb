# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../app/controllers/gtt_sync_controller'

# Guards against the contract disclosing more than Redmine itself would, and
# against gates that a token or an anonymous caller could slip past. Each test
# here corresponds to a finding from the 2026-08 maintainer review; they exist
# so the same hole cannot reopen silently.
class GttSyncDisclosureTest < ActionController::TestCase
  tests GttSyncController

  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles,
           :enabled_modules, :trackers, :projects_trackers, :issue_statuses,
           :issues, :issue_categories, :enumerations, :journals, :journal_details,
           :time_entries, :workflows

  setup do
    Project.find(1).enabled_module_names =
      Project.find(1).enabled_module_names | ['gtt_sync']
    @request.session[:user_id] = 2 # jsmith, member of project 1 via role 1
  end

  def grant(*permissions)
    Role.find(1).update!(permissions: %i[view_issues use_gtt_sync] + permissions)
    User.current = nil
  end

  # --- issue history labels ---

  test 'a project move does not name a project the reader cannot see' do
    grant
    hidden = Project.find(2)
    hidden.update_columns(is_public: false)
    hidden.members.where(user_id: 2).destroy_all
    User.current = nil
    # A journal detail recording a move out of the hidden project.
    journal = Journal.create!(journalized: Issue.find(1), user: User.find(1))
    JournalDetail.create!(journal: journal, property: 'attr',
                          prop_key: 'project_id',
                          old_value: hidden.id.to_s, value: '1')

    get :issue, params: { id: 1 }

    assert_response :success
    body = response.body
    assert_not_includes body, hidden.name,
                        'the name of an invisible project leaked into history'
  end

  test 'a parent change carries the id only, never the parent subject' do
    grant
    parent = Issue.find(2)
    journal = Journal.create!(journalized: Issue.find(1), user: User.find(1))
    JournalDetail.create!(journal: journal, property: 'attr',
                          prop_key: 'parent_id',
                          old_value: nil, value: parent.id.to_s)

    get :issue, params: { id: 1 }

    assert_response :success
    assert_not_includes response.body, parent.subject,
                        'a parent issue subject leaked through a history label'
  end

  # --- time entries ---

  test 'a time entry omits the subject of an issue the reader cannot see' do
    grant(:view_time_entries)
    # Role 1 ships with issues_visibility 'all', which sees private issues by
    # design; 'default' is the setting under which privacy actually applies.
    Role.find(1).update!(issues_visibility: 'default')
    entry = TimeEntry.where.not(issue_id: nil).first
    issue = entry.issue
    issue.update_columns(is_private: true, author_id: 1, assigned_to_id: 1)
    User.current = nil
    assert_not issue.reload.visible?(User.find(2)), 'test premise: issue hidden'

    get :time_entries, params: { from: '1970-01-01' }

    assert_response :success
    entries = response.parsed_body['time_entries']
    mine = entries.select { |e| e.dig('issue', 'id') == issue.id }
    assert(mine.none? { |e| e['issue'].key?('subject') },
           'a private issue subject leaked through a time entry')
  end

  # --- publish_location ---

  test 'an anonymous caller cannot publish a location' do
    Role.anonymous.update!(permissions: [:use_gtt_sync])
    @request.session[:user_id] = nil
    User.current = nil

    post :publish_location, params: {
      location: { 'type' => 'Point', 'coordinates' => [1, 2] }
    }

    # A session request is redirected to the login form, an API request gets a
    # 401; either way the write must not happen.
    assert_not response.successful?
    assert_nil User.anonymous.reload.geom_updated_on
  end

  # --- time entry ownership ---

  test 'a caller-supplied user_id is ignored, not turned into a 422' do
    grant(:log_time, :view_time_entries)

    post :create_time_entry, params: {
      id: 1, hours: 1.5,
      activity_id: TimeEntryActivity.active.first.id,
      # A client that helpfully sends its own user id must not break the write.
      user_id: 3
    }

    assert_response :created
    assert_equal 2, TimeEntry.order(:id).last.user_id
  end
end
