# frozen_string_literal: true

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
  accept_api_auth :capabilities, :issue, :issue_documents, :project_bundle,
                  :project_schema, :query_bundle

  # Hard cap on ids per batch request, so one call can't turn into an
  # unbounded response; a client with a larger scope chunks its requests.
  ISSUE_DOCUMENTS_LIMIT = 100

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
    render json: RedmineGttSync::IssueDocument.build(
      issue, base_url: canonical_base_url, user: User.current
    ), content_type: 'application/ld+json'
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Issue not found' }, status: :not_found
  end

  # Batch form of #issue: ?ids=1,2,3 returns { "issues": [document, ...] } with
  # each entry in exactly the single-issue document shape. Exists for offline
  # packaging (qtask#65/#80/#82), where fetching one document per issue made
  # the serial loop the bottleneck on large scopes.
  #
  # Permission filtering matches the rest of the contract: Issue.visible gives
  # per-project view_issues scoping (visibility, private issues), the
  # use_gtt_sync project gate is pushed into the query like query_bundle, and
  # the per-user parts of each document (private notes, editable contract,
  # visible details) are handled inside IssueDocument.build. Ids that resolve
  # to nothing the user may see are omitted rather than reported, so existence
  # is not leaked - a client treats a missing entry like the single-issue 404.
  def issue_documents
    # Malformed input is a client error (400), unlike a valid id that resolves
    # to nothing (omitted): silently dropping bad tokens would let a broken
    # client read `ids=1,abc` as a clean answer for issue 1. The cap counts raw
    # tokens (before dedup) so repeats can't smuggle an oversized request.
    raw_ids = params[:ids].to_s.split(',', -1)
    if raw_ids.empty?
      return render json: {
        error: 'ids is required: a comma-separated list of issue ids'
      }, status: :bad_request
    end
    if raw_ids.size > ISSUE_DOCUMENTS_LIMIT
      return render json: {
        error: "at most #{ISSUE_DOCUMENTS_LIMIT} ids per request"
      }, status: :bad_request
    end

    ids = raw_ids.map { |raw| Integer(raw.strip, exception: false) }
    if ids.any? { |id| id.nil? || id <= 0 }
      return render json: {
        error: 'ids must be a comma-separated list of positive issue ids'
      }, status: :bad_request
    end

    issues = Issue.visible.where(id: ids.uniq, project_id: gtt_sync_project_ids).to_a
    preload_document_associations(issues)
    base = canonical_base_url
    user = User.current
    render json: {
      'issues' => issues.map do |issue|
        RedmineGttSync::IssueDocument.build(issue, base_url: base, user: user)
      end
    }
  end

  # Whole project in one optimized, permission-scoped payload. Project.visible
  # and Issue.visible enforce the same access control as the rest of Redmine.
  def project_bundle
    project = find_visible_project(params[:id])
    return unless integration_allowed?(project)

    # Eager-load the custom-value associations the bundle serializes
    # (visible_custom_field_values per issue), so a large project doesn't fan
    # out into an N+1 of per-issue custom-value/custom-field queries.
    #
    # Optional query_id narrows the project by a saved query's filters, run in
    # this project's context (mirrors Redmine's projects/:id/issues?query_id=N);
    # without it the whole project loads. Both query.issues and
    # project.issues.visible are view_issues-scoped, so visibility holds either
    # way. use_gtt_sync + view_issues for this single project were checked above.
    #
    # A project-scoped query can span the project's subtree (Redmine includes
    # subprojects when display_subprojects_issues is on, or when the query says
    # so), so the per-project use_gtt_sync gate is applied to the result - a
    # subproject that never enabled the integration must not ride in through
    # its parent's bundle.
    if params[:query_id].present?
      query = IssueQuery.visible.find(params[:query_id])
      query.project = project
      issues = filter_issues_by_gtt_sync(query.issues)
    else
      issues = project.issues.visible.to_a
    end
    preload_issue_associations(issues)
    render json: RedmineGttSync::ProjectBundle.build(
      project, issues, base_url: canonical_base_url, user: User.current
    )
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Project or query not found' }, status: :not_found
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

  # All-projects bundle: issues split by geometry + unplaced, the boundaries of
  # every project represented, and a project directory. Optional query_id
  # applies a saved query's filters across every project the user may integrate
  # with (mirrors Redmine's issues?query_id=N); without it, all visible issues
  # load (the "All projects, no query" scope). Cross-project by nature, so it is
  # gated per project rather than on a single one.
  def query_bundle
    issues =
      if params[:query_id].present?
        # A saved query runs across all projects it spans; gate the resulting
        # (already-materialized) array by use_gtt_sync in Ruby.
        query = IssueQuery.visible.find(params[:query_id])
        filter_issues_by_gtt_sync(query.issues)
      else
        # All projects, no query: push the use_gtt_sync gate into the DB - only
        # issues from projects the user may integrate with - rather than loading
        # every visible issue instance-wide and filtering in Ruby.
        Issue.visible.where(project_id: gtt_sync_project_ids).to_a
      end
    preload_issue_associations(issues)
    render json: RedmineGttSync::QueryBundle.build(
      issues, base_url: canonical_base_url, user: User.current
    )
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Query not found' }, status: :not_found
  end

  private

  # Ids of projects where the current user may use the integration
  # (use_gtt_sync is project-scoped, and Project.allowed_to already factors in
  # module enablement + role, so even an admin only gets module-enabled ones).
  # Not memoized: each action needs it at most once, and cached ids would go
  # stale within a request lifecycle that changes memberships (tests do).
  def gtt_sync_project_ids
    Project.allowed_to(User.current, :use_gtt_sync).ids
  end

  # Keep to issues in gtt_sync-enabled projects, matching on project_id (no
  # per-issue project load). For the cross-project saved-query case, where the
  # issue set is already an in-memory array.
  def filter_issues_by_gtt_sync(issues)
    allowed = gtt_sync_project_ids.to_set
    issues.select { |issue| allowed.include?(issue.project_id) }
  end

  # Preload the associations the bundle serializes (custom values per issue,
  # each issue's project for the project directory, and the reference fields the
  # summary renders as names), so a large result doesn't fan out into per-issue
  # N+1 queries. Takes an array (query.issues / *.to_a), so a relation preload
  # won't do.
  def preload_issue_associations(issues)
    ActiveRecord::Associations::Preloader.new(
      records: issues,
      associations: [
        :project, :priority, :assigned_to, :category, :fixed_version,
        { custom_values: :custom_field }
      ]
    ).call
  end

  # The full-document endpoints serialize the rich sections on top of the
  # summary fields, so batch document builds also preload journals (with users
  # and change details), attachments, changesets, and both relation directions
  # - otherwise a 100-issue batch fans out into hundreds of per-issue queries.
  def preload_document_associations(issues)
    ActiveRecord::Associations::Preloader.new(
      records: issues,
      associations: [
        :status, :tracker, :author, :changesets,
        { journals: %i[user details] },
        { attachments: :author },
        { relations_from: :issue_to, relations_to: :issue_from }
      ]
    ).call
    preload_issue_associations(issues)
  end

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
    RedmineGttSync.canonical_base_url
  end
end
