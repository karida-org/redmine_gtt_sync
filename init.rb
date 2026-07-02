require 'redmine'
require_relative 'lib/redmine_gtt_sync/capabilities'
require_relative 'lib/redmine_gtt_sync/geometry'
require_relative 'lib/redmine_gtt_sync/issue_document'
require_relative 'lib/redmine_gtt_sync/project_bundle'
require_relative 'lib/redmine_gtt_sync/project_schema'

# redmine_gtt_sync provides the integration contract that external clients
# (QTask for QGIS, QField, and OGC clients) use to read and write GTT geometry.
# It builds on redmine_gtt and never duplicates its geometry storage or base API.
Redmine::Plugin.register :redmine_gtt_sync do
  name 'Redmine GTT Sync'
  author 'Karida G.K.'
  description 'Sync/integration contract for GTT geometry: QGIS (QTask), QField, and OGC clients.'
  version '0.1.0'
  url 'https://github.com/karida-org/redmine_gtt_sync'
  author_url 'https://karida.info'

  requires_redmine version_or_higher: '6.1.0'
  requires_redmine_plugin :redmine_gtt, version_or_higher: '0.0.1'

  # Governance: integration access is a per-project module + a per-role
  # permission. A project must enable the `gtt_sync` module AND the user's role
  # must have `use_gtt_sync` to reach the contract endpoints. Composes with
  # Redmine's own view/edit_issues (reading/writing still need those); it never
  # widens access. No `require:` so an admin may grant it to any role (including
  # Non member / Anonymous) for public integration if desired.
  project_module :gtt_sync do
    permission :use_gtt_sync,
               { gtt_sync: %i[project_bundle project_schema issue] }
  end
end
