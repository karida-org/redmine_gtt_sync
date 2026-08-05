# frozen_string_literal: true

# Plugin routes are evaluated inside Redmine's routing context, so route
# declarations are written directly (not wrapped in a draw block).

# User-facing "Connect QGIS" page (any logged-in user): shows the instance URL,
# advertised client_id, and scopes, and serves a downloadable QGIS OAuth2 config.
get 'gtt_sync/connect',
    to: 'gtt_sync_connect#show',
    as: 'gtt_sync_connect'
get 'gtt_sync/connect/qgis_config',
    to: 'gtt_sync_connect#qgis_config',
    as: 'gtt_sync_connect_qgis_config'

# One-click provisioning of the public QTask OAuth application from the plugin
# settings screen (admin only). POST so it is CSRF-protected.
post 'gtt_sync/oauth_application',
     to: 'gtt_sync_settings#create_oauth_application',
     as: 'gtt_sync_create_oauth_application'

# Capabilities probe: lets a client feature-detect what this server supports
# before authenticating or attempting an unsupported operation.
get 'gtt_sync/capabilities',
    to: 'gtt_sync#capabilities',
    as: 'gtt_sync_capabilities',
    defaults: { format: 'json' }

# Batch form of the issue document: ?ids=1,2,3 returns the same per-issue
# JSON-LD documents in one response (capped per request), so offline packaging
# doesn't fan out into one round-trip per issue. Ids the user may not see (or
# that don't exist, or whose project lacks the integration) are omitted, not
# errors - the same non-leaking behavior as the single-issue 404.
get 'gtt_sync/issues',
    to: 'gtt_sync#issue_documents',
    as: 'gtt_sync_issue_documents',
    defaults: { format: 'json' }

# A single issue as a JSON-LD document (canonical @id IRI + geometry as GeoJSON
# and EWKT). Requires auth and respects issue visibility.
get 'gtt_sync/issues/:id',
    to: 'gtt_sync#issue',
    as: 'gtt_sync_issue',
    defaults: { format: 'json' }

# Delta feed: issues changed since a cursor (?since=token), so clients resync
# incrementally instead of re-fetching a whole bundle. Optional project_id
# narrows the scope; known_ids=1 adds the id set for deletion reconciliation.
get 'gtt_sync/changes',
    to: 'gtt_sync#changes',
    as: 'gtt_sync_changes',
    defaults: { format: 'json' }

# Query-driven bundle: any saved query (project-scoped, cross-project, or
# global) as one payload. Generalizes the project bundle. Requires ?query_id=N.
get 'gtt_sync/bundle',
    to: 'gtt_sync#query_bundle',
    as: 'gtt_sync_query_bundle',
    defaults: { format: 'json' }

# One optimized, permission-scoped payload for a whole project: issues split by
# geometry type + unplaced (no geometry) + boundary. :id is a project id or
# identifier.
get 'gtt_sync/projects/:id/bundle',
    to: 'gtt_sync#project_bundle',
    as: 'gtt_sync_project_bundle',
    defaults: { format: 'json' }

# Per-project editing schema: trackers, statuses, custom fields, and the fields
# the current user may write. Lets a client build a permission-aware form.
get 'gtt_sync/projects/:id/schema',
    to: 'gtt_sync#project_schema',
    as: 'gtt_sync_project_schema',
    defaults: { format: 'json' }
