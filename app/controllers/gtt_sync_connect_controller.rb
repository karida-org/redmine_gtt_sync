# User-facing "Connect QGIS" page: a discoverable, self-serve home for the
# connection details a QGIS/QTask user needs, so setup isn't tribal knowledge.
# Any logged-in user may view it (the client_id of a public PKCE app is not a
# secret); it exposes no admin-only data.
class GttSyncConnectController < ApplicationController
  before_action :require_login

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

  def canonical_base_url
    "#{Setting.protocol}://#{Setting.host_name}"
  end
end
