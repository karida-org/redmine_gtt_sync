require 'redmine'
require_relative 'lib/redmine_gtt_sync/oauth'
require_relative 'lib/redmine_gtt_sync/capabilities'
require_relative 'lib/redmine_gtt_sync/geometry'
require_relative 'lib/redmine_gtt_sync/custom_fields'
require_relative 'lib/redmine_gtt_sync/issue_document'
require_relative 'lib/redmine_gtt_sync/project_bundle'
require_relative 'lib/redmine_gtt_sync/query_bundle'
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

  # Which public OAuth application QTask advertises (its client_id) on the
  # capabilities probe, so users don't have to look it up on the admin-only
  # applications page. Empty = advertise scopes/endpoints only. See #26.
  settings default: { 'oauth_application_uid' => '' },
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

# Serve this plugin's assets/ under public/plugin_assets/. This stack does not
# auto-mirror plugin assets (no boot-time mirror, and assets:precompile skips
# plugin_assets), so each plugin links its own - mirroring redmine_canvas_gantt.
# Symlink when possible; fall back to copying where symlinks are unavailable
# (e.g. a Docker volume mount).
begin
  require 'fileutils'
  # Source is derived from this file's own location, so a differently named
  # plugin directory (packaged, vendored, checked out elsewhere) still resolves.
  # The destination uses the plugin id, which is what
  # javascript_include_tag(plugin: 'redmine_gtt_sync') expects under
  # public/plugin_assets/.
  plugin_assets_dir = File.join(__dir__, 'assets')
  public_assets_dir = Rails.root.join('public', 'plugin_assets', 'redmine_gtt_sync')

  # Copy assets into place: stage a full copy in a per-process directory, then
  # swap it in, so a failed or partial copy never leaves a half-populated
  # (JS-404ing) destination, and concurrent boots (a clustered deploy sharing
  # the volume) do not clobber each other's in-progress staging. Best-effort: a
  # lost swap race self-heals on the next boot.
  copy_assets = lambda do
    staged = "#{public_assets_dir}.staged.#{Process.pid}"
    FileUtils.rm_rf(staged)
    begin
      FileUtils.cp_r(plugin_assets_dir, staged)
      FileUtils.rm_rf(public_assets_dir)
      FileUtils.mv(staged, public_assets_dir)
    ensure
      FileUtils.rm_rf(staged)
    end
  end

  if File.directory?(plugin_assets_dir)
    FileUtils.mkdir_p(public_assets_dir.parent)

    if File.symlink?(public_assets_dir)
      # Refresh an outdated symlink target.
      link_target = begin
        File.realpath(public_assets_dir)
      rescue StandardError
        nil
      end
      unless link_target == plugin_assets_dir
        FileUtils.rm_f(public_assets_dir)
        FileUtils.ln_s(plugin_assets_dir, public_assets_dir)
      end
    elsif File.exist?(public_assets_dir)
      # Keep copied assets in sync when a symlink is unavailable.
      copy_assets.call
    else
      begin
        FileUtils.ln_s(plugin_assets_dir, public_assets_dir)
      rescue Errno::EPERM, Errno::EACCES
        copy_assets.call
      end
    end
  end
rescue StandardError => e
  Rails.logger.warn("redmine_gtt_sync: failed to link plugin assets: #{e.message}") if defined?(Rails)
end
