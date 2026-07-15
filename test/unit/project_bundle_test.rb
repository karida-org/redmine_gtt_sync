# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)
require 'ostruct'

class RedmineGttSyncProjectBundleTest < ActiveSupport::TestCase
  setup do
    # summary() reads User.current for the per-feature editable flag; the fake
    # issues stub attributes_editable? themselves, so any user object works.
    User.stubs(:current).returns(stub)
  end

  def factory
    @factory ||= RGeo::Cartesian.preferred_factory(srid: 4326)
  end

  def issue(
    id, geom:, status_id: 1, tracker_id: 2, custom_field_values: [],
    attributes_editable: true, **extra
  )
    record = OpenStruct.new(
      {
        id: id, subject: "Issue #{id}", status_id: status_id,
        tracker_id: tracker_id, lock_version: 0, geom: geom,
        visible_custom_field_values: custom_field_values
      }.merge(extra)
    )
    # Takes a user arg, so it can't be a plain OpenStruct reader.
    record.stubs(:attributes_editable?).returns(attributes_editable)
    record
  end

  # A named reference (priority/assignee/category/version) as the summary reads
  # it: only #name matters.
  def named(name)
    OpenStruct.new(name: name)
  end

  def custom_value(id:, name:, value:, field_format: 'string', multiple: false)
    field = OpenStruct.new(
      id: id, name: name, field_format: field_format, multiple: multiple
    )
    OpenStruct.new(custom_field: field, value: value)
  end

  def ring
    f = factory
    f.linear_ring([f.point(0, 0), f.point(1, 0), f.point(1, 1), f.point(0, 0)])
  end

  def project(with_boundary: true)
    OpenStruct.new(
      id: 2, identifier: 'field-survey', name: 'Field Survey',
      geom: with_boundary ? factory.polygon(ring) : nil
    )
  end

  def build(issues, with_boundary: true)
    RedmineGttSync::ProjectBundle.build(
      project(with_boundary: with_boundary), issues, base_url: 'https://example.com/'
    )
  end

  def test_splits_issues_by_geometry_and_lists_unplaced
    f = factory
    issues = [
      issue(1, geom: f.point(1.0, 2.0)),
      issue(2, geom: f.line_string([f.point(0, 0), f.point(1, 1)])),
      issue(3, geom: f.polygon(ring)),
      issue(4, geom: nil)
    ]
    bundle = build(issues)
    assert_equal 1, bundle['issues']['point']['features'].size
    assert_equal 1, bundle['issues']['line']['features'].size
    assert_equal 1, bundle['issues']['polygon']['features'].size
    unplaced_ids = bundle['issues']['unplaced'].map { |i| i['id'] }
    assert_equal [4], unplaced_ids
  end

  def test_feature_and_summary_shape
    feature = build([issue(1, geom: factory.point(1.0, 2.0))])['issues']['point']['features'][0]
    assert_equal 'Feature', feature['type']
    assert_equal 1, feature['id']
    assert_equal 'Point', feature['geometry']['type']
    assert_equal 1, feature['properties']['status_id']
    assert_equal 2, feature['properties']['tracker_id']
    assert_equal [], feature['properties']['custom_fields']
  end

  def test_summary_carries_standard_list_fields
    # Reference fields ship as display names; dates/times as ISO; done_ratio and
    # estimated_hours as literals. These back the optional issue-list columns.
    built = issue(
      1,
      geom: factory.point(1.0, 2.0),
      priority: named('High'),
      assigned_to: named('Alice'),
      category: named('Roads'),
      fixed_version: named('v2'),
      start_date: Date.new(2026, 7, 1),
      due_date: Date.new(2026, 7, 9),
      done_ratio: 40,
      estimated_hours: 3.5,
      created_on: Time.utc(2026, 6, 1, 8, 0, 0),
      updated_on: Time.utc(2026, 6, 2, 9, 30, 0)
    )
    props = build([built])['issues']['point']['features'][0]['properties']
    assert_equal 'High', props['priority']
    assert_equal 'Alice', props['assigned_to']
    assert_equal 'Roads', props['category']
    assert_equal 'v2', props['fixed_version']
    assert_equal '2026-07-01', props['start_date']
    assert_equal '2026-07-09', props['due_date']
    assert_equal 40, props['done_ratio']
    assert_in_delta 3.5, props['estimated_hours']
    assert_equal '2026-06-01T08:00:00Z', props['created_on']
    assert_equal '2026-06-02T09:30:00Z', props['updated_on']
  end

  def test_summary_carries_per_feature_editable_flag
    # attributes_editable? for the current user, persisted per feature (spatial
    # AND unplaced) so a client can fail closed on map-side editing.
    bundle = build(
      [
        issue(1, geom: factory.point(1.0, 2.0), attributes_editable: true),
        issue(2, geom: factory.point(3.0, 4.0), attributes_editable: false),
        issue(3, geom: nil, attributes_editable: false)
      ]
    )
    features = bundle['issues']['point']['features']
    assert_equal true, features[0]['properties']['editable']
    assert_equal false, features[1]['properties']['editable']
    assert_equal false, bundle['issues']['unplaced'][0]['editable']
  end

  def test_summary_leaves_unset_reference_and_date_fields_null
    # An issue with no assignee / category / version / dates: those keys are
    # present but null, so the client renders blank cells rather than breaking.
    feature = build([issue(1, geom: factory.point(1.0, 2.0))])['issues']['point']['features'][0]
    props = feature['properties']
    nullable = %w[
      priority assigned_to category fixed_version
      start_date due_date created_on updated_on
    ]
    nullable.each do |key|
      assert props.key?(key), "expected #{key} to be present"
      assert_nil props[key], "expected #{key} to be null when unset"
    end
  end

  def test_summary_carries_visible_custom_field_values
    values = [
      custom_value(id: 5, name: 'Severity', value: 'High', field_format: 'list'),
      custom_value(id: 6, name: 'Tags', value: %w[a b], multiple: true)
    ]
    issues = [issue(1, geom: factory.point(1.0, 2.0), custom_field_values: values)]
    feature = build(issues)['issues']['point']['features'][0]
    cfs = feature['properties']['custom_fields']
    assert_equal 2, cfs.size
    assert_equal({ 'id' => 5, 'name' => 'Severity', 'field_format' => 'list',
                   'multiple' => false, 'value' => 'High' }, cfs[0])
    assert_equal %w[a b], cfs[1]['value']
    assert_equal true, cfs[1]['multiple']
  end

  def test_unplaced_summary_also_carries_custom_fields
    values = [custom_value(id: 5, name: 'Severity', value: 'Low')]
    issues = [issue(9, geom: nil, custom_field_values: values)]
    unplaced = build(issues)['issues']['unplaced'][0]
    assert_equal 'Severity', unplaced['custom_fields'][0]['name']
  end

  def test_unplaced_summary_has_no_geometry
    unplaced = build([issue(9, geom: nil)])['issues']['unplaced'][0]
    assert_equal 9, unplaced['id']
    refute unplaced.key?('geometry')
  end

  def test_project_info_and_boundary
    bundle = build([], with_boundary: true)
    assert_equal 'https://example.com/projects/field-survey', bundle['project']['@id']
    assert_equal 'field-survey', bundle['project']['identifier']
    assert_equal 'Polygon', bundle['project']['boundary']['geometry']['type']
  end

  def test_no_boundary_is_null
    assert_nil build([], with_boundary: false)['project']['boundary']
  end

  def test_multipart_geometries_map_to_their_base_category
    f = factory
    issues = [
      issue(1, geom: f.multi_point([f.point(0, 0)])),
      issue(2, geom: f.multi_line_string([f.line_string([f.point(0, 0), f.point(1, 1)])])),
      issue(3, geom: f.multi_polygon([f.polygon(ring)]))
    ]
    bundle = build(issues)
    ids = ->(category) { bundle['issues'][category]['features'].map { |x| x['id'] } }
    assert_equal [1], ids.call('point')
    assert_equal [2], ids.call('line')
    assert_equal [3], ids.call('polygon')
    assert_empty bundle['issues']['unplaced']
  end

  def test_unsupported_geometry_type_falls_back_to_unplaced
    # A geometry type outside the category map (e.g. GeometryCollection, which
    # GTT does not produce) can't go in a single-type layer, so it falls to
    # unplaced rather than being silently dropped. Documents the contract.
    f = factory
    bundle = build([issue(1, geom: f.collection([f.point(0, 0)]))])
    assert_empty bundle['issues']['point']['features']
    unplaced_ids = bundle['issues']['unplaced'].map { |x| x['id'] }
    assert_equal [1], unplaced_ids
  end
end
