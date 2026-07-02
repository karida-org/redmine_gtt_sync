module RedmineGttSync
  # Geometry serialization for the contract: a GeoJSON geometry object and an
  # EWKT string (WKT with an SRID prefix) from an RGeo geometry. Both nil-safe,
  # so an issue without geometry simply yields nil (the document drops the keys).
  module Geometry
    module_function

    # EWKT, e.g. "SRID=4326;Point (135.3575 34.7472 0.0)". EWKT carries the SRID
    # inline, which plain WKT does not, so a consumer needs no side channel.
    def to_ewkt(geom)
      return nil if geom.nil?

      RGeo::WKRep::WKTGenerator.new(
        tag_format: :ewkt, emit_ewkt_srid: true
      ).generate(geom)
    end

    # A GeoJSON geometry object ({"type", "coordinates"}), not a Feature.
    def to_geojson(geom)
      return nil if geom.nil?

      RGeo::GeoJSON.encode(geom)
    end
  end
end
