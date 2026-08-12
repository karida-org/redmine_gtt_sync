# frozen_string_literal: true

module RedmineGttSync
  # Live user locations (issue #93): a field worker publishes their current
  # position so a dispatcher can assign whoever is nearby.
  #
  # redmine_gtt already gives every user a point in users.geom, used as a
  # static home location; this contract lets the mobile app keep it current
  # and adds the freshness stamp that "nearby" needs (users.geom_updated_on -
  # users.updated_on moves on any profile edit and cannot answer it).
  #
  # Privacy by construction: only the latest point is stored, overwriting the
  # previous one, so no movement history ever lands in Redmine. Publishing is
  # the client's choice; reading someone else's location is gated by a
  # dedicated permission.
  module UserLocations
    module_function

    # One user's location on the wire. The point is GeoJSON; last_heard is the
    # ISO 8601 stamp of the last location write, or null when the location has
    # never been published through this contract (an older home location set
    # in the profile has no stamp - honestly "unknown", not "now").
    def location_hash(user)
      {
        'user' => { 'id' => user.id, 'name' => user.name },
        'location' => point_geojson(user.geom),
        'last_heard' => user.geom_updated_on&.iso8601
      }
    end

    # The members whose location +viewer+ may read in +project+: active
    # project members with a usable point, self included. Entries without a
    # renderable location are omitted (a null point is noise for a "who is
    # nearby" list, not information), and so are locked accounts - a
    # deactivated user is not someone to dispatch, matching Redmine's own
    # assignable-principal behavior.
    def index(project, viewer)
      users = project.members.includes(:user).filter_map do |member|
        user = member.user
        user if locatable?(user)
      end
      users << viewer if locatable?(viewer) && users.exclude?(viewer)
      { 'locations' => users.uniq.map { |user| location_hash(user) } }
    end

    # Whether this principal belongs in a "who is nearby" list at all. Groups
    # (also Members) never do; the point must be one this contract can
    # actually render.
    def locatable?(principal)
      principal.is_a?(User) && principal.active? &&
        point_geojson(principal.geom).present?
    end

    # Writes +geojson+ as the user's current location. Accepts a GeoJSON
    # Point or a Feature wrapping one - the same shapes the contract accepts
    # for issue geometry - and rejects anything else, so a malformed payload
    # is a client error rather than a silently dropped write.
    #
    # Returns [ok, error]; the caller renders. The write goes through
    # update_columns on purpose: this is a high-frequency field update that
    # must not touch updated_on, fire profile callbacks, or trip validations
    # unrelated to a moving worker.
    def publish(user, geojson)
      point = extract_point(geojson)
      return [false, 'A GeoJSON Point (or a Feature wrapping one) is required.'] if point.nil?

      lon, lat = point
      return [false, 'Coordinates are out of range.'] unless valid_coordinates?(lon, lat)

      # Deliberately validation- and callback-free: a moving worker's position
      # is a high-frequency field update that must not touch updated_on, fire
      # profile callbacks, or fail on validations unrelated to a coordinate
      # (a half-complete profile must not silently stop location sharing).
      user.update_columns(
        geom: "SRID=4326;POINT(#{lon} #{lat})",
        geom_updated_on: Time.current
      )
      [true, nil]
    end

    # The [lon, lat] pair from a Point or a Feature wrapping one, or nil when
    # the payload is not one of those shapes.
    def extract_point(geojson)
      geometry = case geojson
                 when Hash
                   geojson['type'] == 'Feature' ? geojson['geometry'] : geojson
                 end
      return nil unless geometry.is_a?(Hash) && geometry['type'] == 'Point'

      coordinates = geometry['coordinates']
      return nil unless coordinates.is_a?(Array) && coordinates.size >= 2

      lon = numeric(coordinates[0])
      lat = numeric(coordinates[1])
      return nil if lon.nil? || lat.nil?

      [lon, lat]
    end

    # A coordinate as a float. Numeric strings count: a JSON body carries
    # real numbers, but a form-encoded request carries '135.2', and both are
    # legitimate ways to reach this endpoint. Anything non-numeric is nil, so
    # garbage still fails the shape check instead of becoming 0.0.
    def numeric(value)
      case value
      when Numeric then value.to_f
      when String then Float(value, exception: false)
      end
    end

    def valid_coordinates?(lon, lat)
      lon.between?(-180, 180) && lat.between?(-90, 90)
    end

    # A stored geometry as a GeoJSON Point, or nil when absent. The column is
    # an RGeo geometry; anything that is not a point (never written by this
    # contract) reads as absent rather than as a malformed point.
    def point_geojson(geom)
      return nil if geom.blank?
      return nil unless geom.respond_to?(:x) && geom.respond_to?(:y)

      { 'type' => 'Point', 'coordinates' => [geom.x, geom.y] }
    end
  end
end
