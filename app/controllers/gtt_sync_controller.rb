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
    render json: RedmineGttSync::Capabilities.report
  end
end
