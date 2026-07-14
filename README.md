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
contract on top:

- Capabilities probe (`GET /gtt_sync/capabilities`) so clients can feature-detect.
- Planned: bulk geometry write, geometry-only PATCH, a change feed for efficient
  offline resync, schema introspection (writable fields per user and status), and
  OGC API - Features / WFS-T endpoints.

## Development

Install this plugin alongside `redmine_gtt` under a Redmine checkout's `plugins/`
directory, then run migrations and the plugin test suite from the Redmine root:

```sh
bundle exec rails redmine:plugins:migrate RAILS_ENV=test
bundle exec rails test plugins/redmine_gtt_sync/test
```

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
