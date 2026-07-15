# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)
require 'ostruct'

class RedmineGttSyncProjectSchemaTest < ActiveSupport::TestCase
  def test_custom_field_hash_shape_and_sorted_trackers
    custom_field = OpenStruct.new(
      id: 5, name: 'Severity', field_format: 'list', is_required: true,
      multiple: false, possible_values: %w[Low Medium High],
      trackers: [OpenStruct.new(id: 2), OpenStruct.new(id: 1)]
    )
    # list uses possible_values strings, so value_options stays empty (and the
    # option lookup isn't even called - context is irrelevant here).
    hash = RedmineGttSync::ProjectSchema.custom_field_hash(custom_field, nil)
    assert_equal 5, hash['id']
    assert_equal 'Severity', hash['name']
    assert_equal 'list', hash['field_format']
    assert_equal true, hash['required']
    assert_equal false, hash['multiple']
    assert_equal %w[Low Medium High], hash['possible_values']
    assert_equal [], hash['value_options']
    assert_equal [1, 2], hash['tracker_ids']
  end

  def test_custom_field_hash_without_context_is_backward_compatible
    # Called with just the field (no context): the arity stays compatible and
    # value_options is empty rather than raising on a nil context.
    custom_field = OpenStruct.new(
      id: 7, name: 'Reviewer', field_format: 'user', is_required: false,
      multiple: false, possible_values: nil, trackers: []
    )
    hash = RedmineGttSync::ProjectSchema.custom_field_hash(custom_field)
    assert_equal [], hash['value_options']
  end

  def test_user_custom_field_hash_carries_value_options
    custom_field = OpenStruct.new(
      id: 7, name: 'Reviewer', field_format: 'user', is_required: false,
      multiple: false, possible_values: nil,
      trackers: [OpenStruct.new(id: 1)]
    )
    context = Object.new
    # possible_values_options yields [label, value] pairs for user/version fields.
    custom_field.stubs(:possible_values_options).with(context)
                .returns([%w[Alice 3], %w[Bob 5]])

    hash = RedmineGttSync::ProjectSchema.custom_field_hash(custom_field, context)
    assert_equal 'user', hash['field_format']
    assert_equal(
      [{ 'value' => '3', 'label' => 'Alice' }, { 'value' => '5', 'label' => 'Bob' }],
      hash['value_options']
    )
  end

  def test_writable_and_references_from_first_tracker_stand_in
    project = project_with_tracker(OpenStruct.new(id: 1, name: 'Task'))
    issue = mock('issue')
    issue.stubs(:safe_attribute_names).returns(%w[subject assigned_to_id])
    issue.stubs(:assignable_users).returns([OpenStruct.new(id: 8, name: 'Worker')])
    # The non-writable reference fields must not be queried at all.
    issue.expects(:assignable_versions).never
    Issue.stubs(:new).returns(issue)

    result = RedmineGttSync::ProjectSchema.writable_and_references(project, OpenStruct.new)
    assert_equal %w[subject assigned_to_id], result['writable']
    assert_equal [{ 'id' => 8, 'name' => 'Worker' }],
                 result['references']['assigned_to_id']
    refute result['references'].key?('priority_id')
  end

  def test_writable_and_references_empty_without_tracker
    result = RedmineGttSync::ProjectSchema.writable_and_references(
      project_with_tracker(nil), OpenStruct.new
    )
    assert_equal [], result['writable']
    assert_equal({}, result['references'])
  end

  private

  # A stand-in project whose trackers.sorted.first is +tracker+ (or none when
  # +tracker+ is nil).
  def project_with_tracker(tracker)
    trackers = mock('trackers')
    trackers.stubs(:sorted).returns([tracker].compact)
    OpenStruct.new(trackers: trackers)
  end
end
