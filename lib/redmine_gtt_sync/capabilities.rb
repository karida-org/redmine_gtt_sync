module RedmineGttSync
  # Feature-detection payload for the capabilities probe (GET
  # /gtt_sync/capabilities). Flags reflect what the running build actually
  # provides rather than a hand-maintained list, so a client (QTask) can branch
  # baseline vs enhanced without guessing:
  #
  # - the base geo surface (GeoJSON read/write, spatial filters) is provided by
  #   redmine_gtt, so those flags track whether redmine_gtt is actually installed;
  # - the contract endpoints are provided by this plugin, so each is advertised
  #   only when its route is actually defined. Adding an endpoint (with its named
  #   route) flips the flag on its own; nothing here needs editing per feature.
  module Capabilities
    # capability => the named route that implements it. Route names are
    # provisional until each endpoint lands; the detection is what matters.
    CONTRACT_ROUTES = {
      bulk_geometry_write: :gtt_sync_bulk_geometry,
      geometry_only_patch: :gtt_sync_geometry,
      change_feed: :gtt_sync_changes,
      schema_introspection: :gtt_sync_schema,
      ogc_api_features: :gtt_sync_ogc_features,
      wfs_t: :gtt_sync_wfs_transaction
    }.freeze

    module_function

    def report
      plugin = Redmine::Plugin.find(:redmine_gtt_sync)
      gtt_present = Redmine::Plugin.installed?(:redmine_gtt)

      {
        plugin: plugin.id.to_s,
        version: plugin.version,
        redmine: { version: Redmine::VERSION.to_s, rails: Rails.version },
        requires: { redmine_gtt: gtt_present },
        capabilities: base_capabilities(gtt_present).merge(contract_capabilities)
      }
    end

    # Read/geometry-write surface comes from redmine_gtt; true only when present.
    def base_capabilities(gtt_present)
      {
        geojson_read: gtt_present,
        geojson_write: gtt_present,
        spatial_filter_bbox: gtt_present,
        spatial_filter_distance: gtt_present
      }
    end

    # This plugin's contract endpoints: advertised iff their route is defined.
    def contract_capabilities
      CONTRACT_ROUTES.transform_values { |route_name| route_defined?(route_name) }
    end

    def route_defined?(route_name)
      Rails.application.routes.named_routes.key?(route_name)
    end
  end
end
