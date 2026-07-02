require File.expand_path('../../test_helper', __FILE__)
require 'ostruct'

class RedmineGttSyncProjectSchemaTest < ActiveSupport::TestCase
  def test_custom_field_hash_shape_and_sorted_trackers
    custom_field = OpenStruct.new(
      id: 5, name: 'Severity', field_format: 'list', is_required: true,
      multiple: false, possible_values: %w[Low Medium High],
      trackers: [OpenStruct.new(id: 2), OpenStruct.new(id: 1)]
    )
    hash = RedmineGttSync::ProjectSchema.custom_field_hash(custom_field)
    assert_equal 5, hash['id']
    assert_equal 'Severity', hash['name']
    assert_equal 'list', hash['field_format']
    assert_equal true, hash['required']
    assert_equal false, hash['multiple']
    assert_equal %w[Low Medium High], hash['possible_values']
    assert_equal [1, 2], hash['tracker_ids']
  end
end
