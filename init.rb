# frozen_string_literal: true

require 'redmine'

# Redmine's plugin loader adds every plugin's lib/ as an *eager load* path
# (Redmine::PluginLoader.add_autoload_paths), so Zeitwerk manages these files
# too and derives each constant from its filename. It would expect
# `RedmineGttSync::Oauth` from oauth.rb, while the module is `OAuth`, and a
# production instance (which eager loads, unlike test and development) dies at
# boot with a NameError. Redmine registers the same kind of acronym override for
# html/csv/pdf/url/pop3/imap in config/initializers/zeitwerk.rb.
#
# The key is the exact basename, so this affects only files named oauth.rb.
# redmine_oauth's oauth_client.rb / oauth_provider.rb and Redmine's own
# oauth2_applications_controller.rb are different basenames and unaffected.
Rails.autoloaders.main.inflector.inflect('oauth' => 'OAuth')

require_relative 'lib/redmine_gtt_sync'
require_relative 'lib/redmine_gtt_sync/assets'
require_relative 'lib/redmine_gtt_sync/oauth'
require_relative 'lib/redmine_gtt_sync/capabilities'
require_relative 'lib/redmine_gtt_sync/geometry'
require_relative 'lib/redmine_gtt_sync/custom_fields'
require_relative 'lib/redmine_gtt_sync/reference_options'
require_relative 'lib/redmine_gtt_sync/issue_document'
require_relative 'lib/redmine_gtt_sync/project_bundle'
require_relative 'lib/redmine_gtt_sync/query_bundle'
require_relative 'lib/redmine_gtt_sync/change_feed'
require_relative 'lib/redmine_gtt_sync/project_schema'
require_relative 'lib/redmine_gtt_sync/time_entries'

# redmine_gtt_sync provides the integration contract that external clients
# (QTask for QGIS, QField, and OGC clients) use to read and write GTT geometry.
# It builds on redmine_gtt and never duplicates its geometry storage or base API.
Redmine::Plugin.register :redmine_gtt_sync do
  name 'Redmine GTT Sync'
  author 'Daniel Kastl'
  description 'Sync/integration contract for GTT geometry: QGIS (QTask), QField, and OGC clients.'
  version '0.5.0'
  url 'https://github.com/karida-org/redmine_gtt_sync'
  author_url 'https://github.com/karida-org/redmine_gtt_sync'

  requires_redmine version_or_higher: '6.1.0'
  requires_redmine_plugin :redmine_gtt, version_or_higher: '0.0.1'

  # Governance: integration access is a per-project module + a per-role
  # permission. A project must enable the `gtt_sync` module AND the user's role
  # must have `use_gtt_sync` to reach the contract endpoints. Composes with
  # Redmine's own view/edit_issues (reading/writing still need those); it never
  # widens access. No `require:` so an admin may grant it to any role (including
  # Non member / Anonymous) for public integration if desired.
  # The action map lists every gated endpoint (capabilities stays out: it is
  # the public probe). The controller checks the permission itself, but the map
  # must stay truthful for permission reports and a possible move to the stock
  # authorize filter.
  project_module :gtt_sync do
    permission :use_gtt_sync,
               { gtt_sync: %i[project_bundle project_schema issue
                              issue_documents query_bundle changes] }
    # Reading where colleagues are is dispatcher work, not something every
    # member should get by default: its own permission, off unless granted.
    # Publishing one's OWN location needs no permission (it is the user's own
    # data, and the client decides whether to share at all).
    permission :view_user_locations,
               { gtt_sync: %i[user_locations] }
  end

  # Which public OAuth application QTask advertises (its client_id) on the
  # capabilities probe, so users don't have to look it up on the admin-only
  # applications page. Empty = advertise scopes/endpoints only. See #26.
  settings default: { 'oauth_application_uid' => '',
                      'oauth_mobile_application_uid' => '' },
           partial: 'settings/redmine_gtt_sync'

  # Discoverable, self-serve "Connect QGIS" page (#27). Shown only to users who
  # can actually use the integration (use_gtt_sync in any project; admins pass),
  # matching the controller gate, so it isn't a misleading entry for everyone.
  # Caption is the general "Connect" (this page can host other application
  # connection details later); the page itself keeps its "Connect QGIS" title.
  menu :top_menu, :gtt_sync_connect,
       { controller: 'gtt_sync_connect', action: 'show' },
       caption: :label_gtt_sync_connect_menu,
       if: proc { User.current.allowed_to?(:use_gtt_sync, nil, global: true) }
end

# Make this plugin's assets/ reachable under public/plugin_assets/ (this stack
# does not auto-mirror plugin assets). The how and why live in
# RedmineGttSync::Assets; best-effort, never fails the boot.
RedmineGttSync::Assets.mirror
