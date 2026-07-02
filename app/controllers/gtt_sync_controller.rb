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
  accept_api_auth :capabilities, :issue, :project_bundle, :project_schema

  def capabilities
    render json: RedmineGttSync::Capabilities.report
  end

  # A single issue as a JSON-LD document. Issue.visible enforces the same
  # per-project/role visibility as the rest of Redmine; a hidden or missing id
  # is a 404 either way, so existence is not leaked.
  def issue
    issue = Issue.visible.find(params[:id])
    return unless integration_allowed?(issue.project)

    # Serve as JSON-LD so clients/intermediaries interpret the @context/@id.
    render json: RedmineGttSync::IssueDocument.build(issue, base_url: canonical_base_url),
           content_type: 'application/ld+json'
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Issue not found' }, status: :not_found
  end

  # Whole project in one optimized, permission-scoped payload. Project.visible
  # and Issue.visible enforce the same access control as the rest of Redmine.
  def project_bundle
    project = find_visible_project(params[:id])
    return unless integration_allowed?(project)

    issues = project.issues.visible.to_a
    render json: RedmineGttSync::ProjectBundle.build(
      project, issues, base_url: canonical_base_url
    )
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Project not found' }, status: :not_found
  end

  # Per-project editing schema (trackers/statuses/custom fields/writable fields)
  # for the current user.
  def project_schema
    project = find_visible_project(params[:id])
    return unless integration_allowed?(project)

    render json: RedmineGttSync::ProjectSchema.build(project, User.current)
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Project not found' }, status: :not_found
  end

  private

  # Governance gate: integration access requires BOTH
  # - :use_gtt_sync (which already encompasses the gtt_sync module being enabled:
  #   Redmine gates module-scoped permissions, and even admins don't bypass a
  #   disabled module), AND
  # - :view_issues, since these endpoints expose issue data — a role with
  #   use_gtt_sync but not view_issues must not receive project/issue payloads.
  # The project is visible either way, so this is a 403 (not 404). Composes on
  # top of each action's own visibility scoping.
  def integration_allowed?(project)
    user = User.current
    if user.allowed_to?(:use_gtt_sync, project) &&
       user.allowed_to?(:view_issues, project)
      return true
    end

    render json: {
      error: 'GTT integration is not enabled for this project or your role.'
    }, status: :forbidden
    false
  end

  # Resolve a project by id or identifier within the user's visibility, or raise
  # RecordNotFound (a hidden project is indistinguishable from a missing one).
  def find_visible_project(param)
    key = param.to_s
    project = Project.visible.find_by(identifier: key)
    project ||= Project.visible.find_by(id: key) if key.match?(/\A\d+\z/)
    project || raise(ActiveRecord::RecordNotFound)
  end

  # The instance's canonical origin (not the request host), so IRIs are stable
  # regardless of how the request arrived.
  def canonical_base_url
    "#{Setting.protocol}://#{Setting.host_name}"
  end
end
