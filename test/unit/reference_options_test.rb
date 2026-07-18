# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)
require File.expand_path('../../doubles', __FILE__)

class RedmineGttSyncReferenceOptionsTest < ActiveSupport::TestCase
  include RedmineGttSync::TestDoubles

  def test_offers_options_only_for_writable_fields
    issue = IssueDouble.new(
      project: ProjectDouble.new,
      assignable_users: [NamedRef.new(id: 8, name: 'Field Worker')]
    )
    IssuePriority.stubs(:active).returns([NamedRef.new(id: 2, name: 'Normal')])
    # A non-writable field's option source must never be queried.
    issue.expects(:assignable_versions).never
    issue.project.expects(:issue_categories).never

    refs = RedmineGttSync::ReferenceOptions.for_issue(
      issue, %w[subject assigned_to_id priority_id]
    )
    assert_equal [{ 'id' => 8, 'name' => 'Field Worker' }], refs['assigned_to_id']
    assert_equal [{ 'id' => 2, 'name' => 'Normal' }], refs['priority_id']
    refute refs.key?('category_id')
    refute refs.key?('fixed_version_id')
  end

  def test_covers_all_four_reference_fields
    issue = IssueDouble.new(
      project: ProjectDouble.new(issue_categories: [NamedRef.new(id: 3, name: 'Signs')]),
      assignable_users: [NamedRef.new(id: 8, name: 'Worker')],
      assignable_versions: [NamedRef.new(id: 4, name: 'v1')]
    )
    IssuePriority.stubs(:active).returns([NamedRef.new(id: 2, name: 'Normal')])

    refs = RedmineGttSync::ReferenceOptions.for_issue(
      issue, %w[assigned_to_id priority_id category_id fixed_version_id]
    )
    assert_equal %w[assigned_to_id priority_id category_id fixed_version_id].sort,
                 refs.keys.sort
    assert_equal [{ 'id' => 3, 'name' => 'Signs' }], refs['category_id']
    assert_equal [{ 'id' => 4, 'name' => 'v1' }], refs['fixed_version_id']
  end
end
