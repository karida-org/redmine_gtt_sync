# Plugin routes are evaluated inside Redmine's routing context, so route
# declarations are written directly (not wrapped in a draw block).

# Capabilities probe: lets a client feature-detect what this server supports
# before authenticating or attempting an unsupported operation.
get 'gtt_sync/capabilities',
    to: 'gtt_sync#capabilities',
    as: 'gtt_sync_capabilities',
    defaults: { format: 'json' }

# A single issue as a JSON-LD document (canonical @id IRI + geometry as GeoJSON
# and EWKT). Requires auth and respects issue visibility.
get 'gtt_sync/issues/:id',
    to: 'gtt_sync#issue',
    as: 'gtt_sync_issue',
    defaults: { format: 'json' }

# One optimized, permission-scoped payload for a whole project: issues split by
# geometry type + unplaced (no geometry) + boundary. :id is a project id or
# identifier.
get 'gtt_sync/projects/:id/bundle',
    to: 'gtt_sync#project_bundle',
    as: 'gtt_sync_project_bundle',
    defaults: { format: 'json' }
