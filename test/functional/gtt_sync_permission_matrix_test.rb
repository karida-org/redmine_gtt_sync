# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../app/controllers/gtt_sync_controller'

# Role-permission matrix over the REAL Redmine RBAC (qtask#185): a member's
# role is granted exactly the permissions of each case, and the issue document
# / bundle flags must reflect what Redmine will actually accept. This pins the
# server side of the client/server permission contract against Redmine's own
# permission methods (no stubs), so the advertised flags can't drift from
# enforcement.
#
# Fixture cast: project 1 (eCookbook, public), user 2 (jsmith, member of
# project 1 via role 1), user 3 (dlopper, member via role 2), issue 1
# (project 1, tracker 1).
class GttSyncPermissionMatrixTest < ActionController::TestCase
  tests GttSyncController

  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles,
           :enabled_modules, :trackers, :projects_trackers, :issue_statuses,
           :issues, :journals, :journal_details, :workflows,
           :enumerations

  BASE = %i[view_issues use_gtt_sync].freeze

  setup do
    project = Project.find(1)
    project.enabled_module_names = project.enabled_module_names | ['gtt_sync']
    @request.session[:user_id] = 2 # jsmith, member of project 1 via role 1
  end

  def grant(*permissions)
    Role.find(1).update!(permissions: BASE + permissions)
    User.current = nil # drop Redmine's per-request permission memoization
  end

  def issue_document(issue_id = 1)
    get :issue, params: { id: issue_id }
    assert_response :success
    JSON.parse(response.body)
  end

  def editable(issue_id = 1)
    issue_document(issue_id)['editable']
  end

  test 'view-only role: every write affordance is off' do
    grant # nothing beyond view_issues + use_gtt_sync
    contract = editable
    assert_equal false, contract['can_delete']
    assert_equal false, contract['can_add_notes']
    assert_equal false, contract['can_add_attachments']
    assert_equal [], contract['status_transitions']
    # No edit permission: Redmine offers no writable attributes.
    assert_equal [], contract['fields']
  end

  test 'edit_issues grants fields, transitions, and attachment adds - not delete' do
    grant :edit_issues
    contract = editable
    assert_includes contract['fields'], 'subject'
    assert_includes contract['fields'], 'description'
    # The per-tracker workflow for role 1 / tracker 1 offers real transitions.
    assert_not_empty contract['status_transitions']
    assert_equal true, contract['can_add_attachments']
    assert_equal false, contract['can_delete']
    assert_equal false, contract['can_add_notes']
  end

  test 'add_issue_notes alone grants notes and attachment adds - not fields' do
    grant :add_issue_notes
    contract = editable
    assert_equal true, contract['can_add_notes']
    # Redmine's attach rule is add_issue_notes OR edit_issues.
    assert_equal true, contract['can_add_attachments']
    assert_equal false, contract['can_delete']
    assert_not_includes contract['fields'], 'subject'
    assert_equal [], contract['status_transitions']
  end

  test 'delete_issues grants exactly the delete flag' do
    grant :delete_issues
    contract = editable
    assert_equal true, contract['can_delete']
    assert_equal false, contract['can_add_notes']
    assert_equal false, contract['can_add_attachments']
  end

  test 'edit_own_issue_notes marks only own notes editable' do
    own = new_note(1, User.find(2), 'my own note')
    other = new_note(1, User.find(3), 'someone else')

    grant :add_issue_notes, :edit_own_issue_notes
    flags = note_editability(issue_document)
    assert_equal true, flags[own.id], 'own note must be editable'
    assert_equal false, flags[other.id], "another user's note must not be"
  end

  test 'edit_issue_notes marks all notes editable' do
    own = new_note(1, User.find(2), 'my own note')
    other = new_note(1, User.find(3), 'someone else')

    grant :add_issue_notes, :edit_issue_notes
    flags = note_editability(issue_document)
    assert_equal true, flags[own.id]
    assert_equal true, flags[other.id]
  end

  test 'private notes are omitted without view_private_notes and shown with it' do
    secret = new_note(1, User.find(1), 'internal-only remark', private: true)

    grant # no view_private_notes
    ids = issue_document['journals'].map { |j| j['id'] }
    assert_not_includes ids, secret.id

    grant :view_private_notes
    journals = issue_document['journals']
    entry = journals.find { |j| j['id'] == secret.id }
    assert entry, 'private note must appear with view_private_notes'
    assert_equal true, entry['private_notes']
  end

  test 'bundle features carry editable=false without edit_issues and true with it' do
    grant # view-only
    assert_equal [false], bundle_editable_values.uniq

    grant :edit_issues
    assert_equal [true], bundle_editable_values.uniq
  end

  test 'a plain member with use_gtt_sync passes the governance gate' do
    # The positive half of the gate (the negative 403s are covered in the main
    # controller test): a non-admin member whose role holds use_gtt_sync gets in.
    grant
    get :issue, params: { id: 1 }
    assert_response :success
  end

  private

  # Adds a journal note as +user+ and returns it. Loads the issue fresh each
  # time: init_journal + save! on an already-clean instance is a no-op (no new
  # journal), so reusing one instance would silently return the prior journal.
  def new_note(issue_id, user, text, private: false)
    issue = Issue.find(issue_id)
    issue.init_journal(user, text)
    issue.current_journal.private_notes = private
    issue.save!
    issue.current_journal
  end

  # {journal_id => notes_editable} for journals that carry a note.
  def note_editability(document)
    document['journals'].each_with_object({}) do |journal, flags|
      next unless journal.key?('notes_editable')

      flags[journal['id']] = journal['notes_editable']
    end
  end

  def bundle_editable_values
    get :project_bundle, params: { id: 'ecookbook' }
    assert_response :success
    body = JSON.parse(response.body)
    spatial = %w[point line polygon].flat_map do |kind|
      body['issues'][kind]['features'].map { |f| f['properties']['editable'] }
    end
    spatial + body['issues']['unplaced'].map { |i| i['editable'] }
  end
end
