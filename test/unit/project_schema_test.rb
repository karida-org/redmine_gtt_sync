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
end
