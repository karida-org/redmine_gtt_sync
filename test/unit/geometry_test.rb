# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

class RedmineGttSyncGeometryTest < ActiveSupport::TestCase
  def factory
    @factory ||= RGeo::Cartesian.preferred_factory(srid: 4326, has_z_coordinate: true)
  end

  def test_to_ewkt_carries_srid_and_coordinates
    ewkt = RedmineGttSync::Geometry.to_ewkt(factory.point(135.3575, 34.7472, 0.0))
    assert ewkt.start_with?('SRID=4326;'), ewkt
    assert_includes ewkt, '135.3575'
  end

  def test_to_geojson_returns_a_geometry_object
    geojson = RedmineGttSync::Geometry.to_geojson(factory.point(1.0, 2.0, 0.0))
    assert_equal 'Point', geojson['type']
    assert_equal [1.0, 2.0, 0.0], geojson['coordinates']
  end

  def test_nil_geometry_is_nil
    assert_nil RedmineGttSync::Geometry.to_ewkt(nil)
    assert_nil RedmineGttSync::Geometry.to_geojson(nil)
  end
end
