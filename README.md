# redmine_gtt_sync

Synchronize Redmine GTT issues with external applications and services.

`redmine_gtt_sync` is the open server-side contract that external clients use to
read and write GTT geometry: [QTask](https://github.com/karida-org/qtask) for
QGIS, QField, and other OGC clients. It builds on
[`redmine_gtt`](https://github.com/gtt-project/redmine_gtt) and never duplicates
its geometry storage or base geo API.

## Requirements

- Redmine 6.1 or higher (RedMica-based builds included).
- `redmine_gtt` installed (hard dependency, enforced at load).

## What it provides

The baseline geo API (GeoJSON read/write, `bbox` and `distance` spatial filters)
comes from `redmine_gtt`. This plugin adds the client-facing integration
contract on top. Every endpoint runs as the authenticated user through
Redmine's own visibility scopes and `safe_attributes`; the plugin is a query
optimizer and response shaper, never a privileged path.

Shipped:

- **Capabilities probe** (`GET /gtt_sync/capabilities`, public): version info,
  feature flags self-reported from the defined routes (see
  `lib/redmine_gtt_sync/capabilities.rb`), the instance's rich-text formatting,
  and the OAuth2 setup parameters (endpoints, scopes, and the advertised
  public client id when an admin selected one).
- **Project and query bundles** (`GET /gtt_sync/projects/:id/bundle`, plus an
  all-projects variant, both accepting an optional `query_id`): one
  permission-scoped call returning the issues (including unplaced,
  geometry-less ones), the project boundary, lookups, and per-feature
  `iri`/`lock_version`/`editable` data a client needs to build its layers.
- **Issue documents**: a single-issue rich document (description, journals,
  attachments, relations) and a batch endpoint used for offline packaging.
- **Schema introspection** (`GET /gtt_sync/projects/:id/schema`): trackers,
  custom fields, references, and the writable field set per user, so clients
  can grey out what they may not write instead of losing edits to silent
  `safe_attributes` drops.
- **OAuth onboarding**: a plugin setting selects (or one-click creates) the
  public PKCE OAuth application to advertise, and a "Connect QGIS" page (any
  logged-in user) shows the connection details and serves a downloadable QGIS
  OAuth2 config, so a non-admin can connect knowing only the instance URL.
- **Governance**: a `gtt_sync` project module and a `use_gtt_sync` role
  permission gate integration access per project and per role, composing on
  top of (never bypassing) the normal issue permissions.

Planned (tracked in issues): bulk geometry write (#9), geometry-only PATCH
(#10), a change feed for efficient offline resync (#7), OGC API - Features /
WFS-T endpoints (#11), server-side export formats (#16), and a paged bundle
for large issue sets (#35).

## Development

Install this plugin alongside `redmine_gtt` under a Redmine checkout's `plugins/`
directory, then run migrations and the plugin test suite from the Redmine root:

```sh
bundle exec rails redmine:plugins:migrate RAILS_ENV=test
bundle exec rails test plugins/redmine_gtt_sync/test
```

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
