# User-facing "Connect QGIS" page: a discoverable, self-serve home for the
# connection details a QGIS/QTask user needs, so setup isn't tribal knowledge.
# The data isn't secret (a public PKCE client_id is not), but the page is only
# useful to someone who can actually use the integration, so it is gated on the
# same permission the API endpoints require - held in ANY project - so a user
# who couldn't use gtt_sync anywhere doesn't see a misleading "Connect" page.
class GttSyncConnectController < ApplicationController
  before_action :require_login
  before_action :require_gtt_sync_access

  def show
    @base_url = canonical_base_url
    @client_id = RedmineGttSync::Capabilities.advertised_oauth_client_id
    @scopes = RedmineGttSync::OAuth::SCOPES
  end

  # Downloadable QGIS OAuth2 config the user imports via QGIS's auth import
  # button. Only offered when the instance advertises a client_id.
  def qgis_config
    client_id = RedmineGttSync::Capabilities.advertised_oauth_client_id
    return render_404 unless client_id

    send_data JSON.pretty_generate(
      RedmineGttSync::OAuth.qgis_oauth2_config(canonical_base_url, client_id)
    ), filename: 'qtask-oauth2.json', type: 'application/json', disposition: 'attachment'
  end

  private

  # Any-project check: true if the user holds use_gtt_sync in at least one
  # project (admins always pass). Mirrors the API's integration gate.
  def require_gtt_sync_access
    return if User.current.allowed_to?(:use_gtt_sync, nil, global: true)

    render_403
  end

  def canonical_base_url
    "#{Setting.protocol}://#{Setting.host_name}"
  end
end
