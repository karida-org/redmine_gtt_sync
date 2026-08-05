# redmine_gtt_sync

Synchronize Redmine GTT issues with external applications and services.

`redmine_gtt_sync` is the open server-side contract that external clients use
to read and write GTT geometry: [QTask](https://github.com/karida-org/qtask)
for QGIS, QField, and other OGC clients. It builds on
[`redmine_gtt`](https://github.com/gtt-project/redmine_gtt) and never
duplicates its geometry storage or base geo API.

## How it works

The baseline geo API (GeoJSON read/write, `bbox` and `distance` spatial
filters) comes from `redmine_gtt`. This plugin adds a client-facing
integration contract on top:

- Every endpoint runs as the authenticated user, through Redmine's own
  visibility scopes and `safe_attributes`. The plugin is a query optimizer and
  response shaper, never a privileged path.
- Access is opt-in twice: a project must enable the **GTT Sync** module, and
  the user's role must have the **Use GTT Sync** permission. This composes
  with the normal issue permissions (`view_issues`, `edit_issues`, ...) and
  never widens them.
- Clients discover what the server offers through a public capabilities
  probe, so an old client against a new server (or the reverse) degrades
  cleanly instead of breaking.

## Requirements

- Redmine 6.1 or higher (RedMica-based builds included).
- `redmine_gtt` installed (hard dependency, enforced at load). The geometry
  gems (`rgeo` and friends) arrive through `redmine_gtt`'s own Gemfile.

## Installation

1. Put this plugin (and `redmine_gtt`) under the Redmine root's `plugins/`
   directory:

   ```sh
   cd /path/to/redmine/plugins
   git clone https://github.com/karida-org/redmine_gtt_sync.git
   ```

2. Install gems and restart Redmine:

   ```sh
   bundle install
   ```

   The plugin has no database migrations of its own.

## Setup

1. **Enable the module**: in each project that should be reachable from QGIS,
   open *Settings > Modules* and enable **GTT Sync**.
2. **Grant the permission**: in *Administration > Roles and permissions*, give
   **Use GTT Sync** to the roles that may use the integration.
3. **Turn on OAuth sign-in (recommended)**: in *Administration > Plugins >
   Redmine GTT Sync > Configure*, click *Set up the QGIS / QTask connection*.
   This creates a public PKCE OAuth application (no secret involved) and
   advertises its client id on the capabilities probe. The button is safe to
   click again later; it re-checks and repairs the settings.
4. **Point users at the Connect page**: the *Connect* item in the top menu
   (visible to users who hold the permission somewhere) shows the instance
   URL, client id, and scopes, and serves a downloadable QGIS OAuth2 config.

API-key authentication also works on every endpoint; OAuth is the recommended
path because users sign in with their own account and tokens carry
least-privilege scopes.

## Endpoints

All endpoints return JSON and respect the access rules above.

| Endpoint | Purpose |
| --- | --- |
| `GET /gtt_sync/capabilities` | Public feature-detection probe: plugin/Redmine versions, per-endpoint flags, text formatting, OAuth parameters. |
| `GET /gtt_sync/projects/:id/bundle` | One optimized payload for a project: issues split by geometry type, geometry-less ("unplaced") issues, and the project boundary. Optional `query_id` applies a saved query's filters. |
| `GET /gtt_sync/bundle?query_id=N` | The same payload across all projects the user may integrate with; `query_id` is optional here too. |
| `GET /gtt_sync/issues/:id` | A single issue as a JSON-LD document: geometry (GeoJSON + EWKT), journals, relations, attachments, custom fields, and the per-user editing contract. |
| `GET /gtt_sync/issues?ids=1,2,3` | Batch form of the issue document (up to 100 ids per request), used for offline packaging. |
| `GET /gtt_sync/projects/:id/schema` | Per-project editing schema: trackers, statuses, custom fields, writable field names, and reference options for the current user. |
| `GET /gtt_sync/changes?since=<token>` | Delta feed: issues changed since a cursor, so clients resync incrementally. Optional `project_id` narrows the scope; `known_ids=1` adds the full id set for deletion reconciliation. |

A few details matter for client authors:

- **Nothing leaks**: ids the user may not see are omitted (batch) or answered
  with 404 (single), so existence is never revealed.
- **The editing contract is advertised, and enforced**: `editable` flags and
  `writable` field lists tell a client what this user may change, so it can
  disable the rest of its UI. The server still enforces everything on write;
  the flags only prevent a client from offering edits Redmine would reject or
  silently drop.
- **The change feed is at-least-once, and never loses a change**: pass the
  `next_since` token from each response into the next request, apply entries
  idempotently by issue id, and follow `more` until it is false. The first
  request may pass a plain ISO 8601 time. Very recent changes appear after a
  short settle delay (about ten seconds), so a slow write can never fall
  behind the cursor. Deletions are not events in the feed - an issue can also
  simply leave your visibility - so periodically request `known_ids=1` and
  drop local issues missing from the returned set.

Planned (tracked in issues): a read-only OGC API - Features endpoint (#11),
and - each gated on real-world demand or evidence - a server-side project
GeoPackage export (#16), a bulk geometry write (#9), and a paged bundle for
large issue sets (#35).

## Development

Install this plugin alongside `redmine_gtt` under a Redmine checkout's
`plugins/` directory, then run the plugin test suite from the Redmine root:

```sh
bundle exec rails redmine:plugins:migrate RAILS_ENV=test
bundle exec rails test plugins/redmine_gtt_sync/test
```

Style is checked with RuboCop, using the configuration in this repository:

```sh
rubocop -c plugins/redmine_gtt_sync/.rubocop.yml plugins/redmine_gtt_sync
```

Code layout:

- `app/controllers/` - the HTTP layer: parameter checks, access gates, and
  wiring. No response shaping.
- `lib/redmine_gtt_sync/` - one module per concern (capabilities report,
  OAuth advertisement, issue document, bundles, schema, geometry encoding,
  asset mirroring). These modules shape data; permissions are delegated to
  Redmine's own model methods and the acting user is always passed in
  explicitly.
- `test/unit/` - shaping logic against typed doubles (`test/doubles.rb`).
- `test/functional/` - controllers against real Redmine fixtures, including a
  role-permission matrix that pins the advertised editing contract to what
  Redmine actually enforces.

User-facing strings live in `config/locales/en.yml` and `ja.yml`; a test
keeps the two files on the same key set, so add every new string to both.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
