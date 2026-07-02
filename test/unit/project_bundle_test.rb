require File.expand_path('../../test_helper', __FILE__)
require 'ostruct'

class RedmineGttSyncProjectBundleTest < ActiveSupport::TestCase
  def factory
    @factory ||= RGeo::Cartesian.preferred_factory(srid: 4326)
  end

  def issue(id, geom:, status_id: 1, tracker_id: 2)
    OpenStruct.new(
      id: id, subject: "Issue #{id}", status_id: status_id,
      tracker_id: tracker_id, lock_version: 0, geom: geom
    )
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
