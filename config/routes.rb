# Plugin routes are evaluated inside Redmine's routing context, so route
# declarations are written directly (not wrapped in a draw block).

# Capabilities probe: lets a client feature-detect what this server supports
# before authenticating or attempting an unsupported operation.
get 'gtt_sync/capabilities', to: 'gtt_sync#capabilities', defaults: { format: 'json' }
