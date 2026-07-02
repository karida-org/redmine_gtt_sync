# Endpoints for the QGIS/QField/OGC integration contract.
#
# Exposes a public capabilities probe and a single-issue JSON-LD document.
# Further contract endpoints (bulk geometry write, geometry-only PATCH, change
# feed, schema introspection, OGC API - Features / WFS-T) land in follow-ups.
class GttSyncController < ApplicationController
  # Capabilities is a public probe: a client should be able to discover what
  # the server offers before it has credentials. The issue document is real
  # data, so it stays behind login + visibility.
  skip_before_action :check_if_login_required, only: [:capabilities]
  accept_api_auth :capabilities, :issue

  def capabilities
    render json: RedmineGttSync::Capabilities.report
  end

  # A single issue as a JSON-LD document. Issue.visible enforces the same
  # per-project/role visibility as the rest of Redmine; a hidden or missing id
  # is a 404 either way, so existence is not leaked.
  def issue
    issue = Issue.visible.find(params[:id])
    # Serve as JSON-LD so clients/intermediaries interpret the @context/@id.
    render json: RedmineGttSync::IssueDocument.build(issue, base_url: canonical_base_url),
           content_type: 'application/ld+json'
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Issue not found' }, status: :not_found
  end

  private

  # The instance's canonical origin (not the request host), so IRIs are stable
  # regardless of how the request arrived.
  def canonical_base_url
    "#{Setting.protocol}://#{Setting.host_name}"
  end
end
