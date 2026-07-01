# Endpoints for the QGIS/QField/OGC integration contract.
#
# For now this only exposes a capabilities probe. Real contract endpoints
# (bulk geometry write, geometry-only PATCH, change feed, schema
# introspection, OGC API - Features / WFS-T) land in follow-up issues.
class GttSyncController < ApplicationController
  # Capabilities is a public probe: a client should be able to discover what
  # the server offers before it has credentials.
  skip_before_action :check_if_login_required, only: [:capabilities]
  accept_api_auth :capabilities

  def capabilities
    plugin = Redmine::Plugin.find(:redmine_gtt_sync)

    render json: {
      plugin: plugin.id.to_s,
      version: plugin.version,
      requires: {
        # geometry storage and the base geo API come from redmine_gtt
        redmine_gtt: Redmine::Plugin.installed?(:redmine_gtt)
      },
      capabilities: {
        # provided today by redmine_gtt
        geojson_read: true,
        geojson_write: true,
        spatial_filter_bbox: true,
        spatial_filter_distance: true,
        # provided by this plugin (not yet implemented)
        bulk_geometry_write: false,
        geometry_only_patch: false,
        change_feed: false,
        schema_introspection: false,
        ogc_api_features: false,
        wfs_t: false
      }
    }
  end
end
