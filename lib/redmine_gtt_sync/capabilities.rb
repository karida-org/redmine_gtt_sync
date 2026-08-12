# frozen_string_literal: true

module RedmineGttSync
  # Feature-detection payload for the capabilities probe (GET
  # /gtt_sync/capabilities). Flags reflect what the running build actually
  # provides rather than a hand-maintained list, so a client (QTask) can branch
  # baseline vs enhanced without guessing:
  #
  # - the base geo surface (GeoJSON read/write, spatial filters) is provided by
  #   redmine_gtt, so those flags track whether redmine_gtt is actually installed;
  # - the contract endpoints are provided by this plugin, so each is advertised
  #   only when its route is actually defined. Adding an endpoint (with its named
  #   route) flips the flag on its own; nothing here needs editing per feature.
  module Capabilities
    # capability => the named route that implements it. Keys whose route does
    # not exist yet are deliberate: they report false today and flip to true on
    # their own the moment the endpoint lands with its named route (see the
    # module comment). Their route names are provisional until then; each is
    # tagged with the issue that tracks the planned endpoint.
    CONTRACT_ROUTES = {
      issue_jsonld: :gtt_sync_issue,
      issue_documents_batch: :gtt_sync_issue_documents,
      project_bundle: :gtt_sync_project_bundle,
      query_bundle: :gtt_sync_query_bundle,
      bulk_geometry_write: :gtt_sync_bulk_geometry, # evidence-gated: issue #9
      # Closed as obsolete (#10): a sparse PUT with lock_version already is a
      # geometry-only write. The flag stays advertised (false) so old clients
      # that probe it keep getting an honest answer.
      geometry_only_patch: :gtt_sync_geometry,
      change_feed: :gtt_sync_changes,
      schema_introspection: :gtt_sync_project_schema,
      time_entries: :gtt_sync_time_entries,
      time_entry_create: :gtt_sync_issue_time_entries,
      user_location_publish: :gtt_sync_user_location,
      user_locations: :gtt_sync_project_user_locations,
      ogc_api_features: :gtt_sync_ogc_features, # planned: issue #11 (read-only)
      # Not planned (dropped from #11): legacy XML transactions nobody in this
      # ecosystem asks for; standards writes would be OGC API Part 4 instead.
      # The flag stays advertised (false) for honest feature detection.
      wfs_t: :gtt_sync_wfs_transaction
    }.freeze

    module_function

    def report
      plugin = Redmine::Plugin.find(:redmine_gtt_sync)
      gtt = Redmine::Plugin.installed?(:redmine_gtt) ? Redmine::Plugin.find(:redmine_gtt) : nil
      gtt_present = !gtt.nil?

      {
        plugin: plugin.id.to_s,
        version: plugin.version,
        redmine: { version: Redmine::VERSION.to_s, rails: Rails.version },
        # Report redmine_gtt's version, not just presence: the base geo surface
        # depends on it, so a client may need to know which release is running.
        requires: { redmine_gtt: gtt_present, redmine_gtt_version: gtt&.version&.to_s },
        capabilities: base_capabilities(gtt_present).merge(contract_capabilities, behavior_capabilities),
        # The instance's rich-text formatter. A client that renders Markdown
        # itself (QTask) must know whether the instance actually authors in
        # Markdown: on a Textile instance, client-side Markdown rendering would
        # be wrong, so it can disable that UX. `markdown` is the convenience flag.
        formatting: formatting_info,
        # OAuth2 setup parameters so a client can build its auth config without
        # the user knowing the scopes/endpoints. Public probe: scopes/endpoints
        # always, plus the client_id only when an admin selected a public app to
        # advertise (see advertised_oauth_client_id); never a client secret.
        oauth: RedmineGttSync::OAuth.advertisement(
          canonical_base_url,
          client_id: advertised_oauth_client_id,
          mobile_client_id: advertised_mobile_oauth_client_id
        )
      }
    end

    # The rich-text formatter the instance authors in. Only common_mark and
    # textile are registered on modern RedMica/Redmine (Redcarpet's `markdown`
    # is gone), but treat a legacy `markdown` as Markdown-capable too. Anything
    # else (e.g. textile, or a null formatter) reports markdown: false so a
    # Markdown-rendering client turns that UX off rather than mis-rendering.
    def formatting_info
      fmt = Setting.text_formatting.to_s
      { text_formatting: fmt, markdown: %w[common_mark markdown].include?(fmt) }
    end

    # The instance's canonical origin (Setting, not request host) so advertised
    # OAuth endpoints are stable regardless of how the probe was reached.
    def canonical_base_url
      RedmineGttSync.canonical_base_url
    end

    # client_id of the admin-selected OAuth application, or nil. Only public
    # (non-confidential) apps are eligible: a public PKCE client_id is not a
    # secret, but a confidential one must never be advertised. A stored uid that
    # no longer resolves to a public app (deleted, or flipped to confidential)
    # advertises nothing rather than leaking.
    def advertised_oauth_client_id
      advertised_public_application_uid('oauth_application_uid')
    end

    # Same rules for the mobile app selection.
    def advertised_mobile_oauth_client_id
      advertised_public_application_uid('oauth_mobile_application_uid')
    end

    def advertised_public_application_uid(setting_key)
      uid = Setting.plugin_redmine_gtt_sync[setting_key].presence
      return nil unless uid

      Doorkeeper::Application.where(confidential: false).find_by(uid: uid)&.uid
    end

    # Read/geometry-write surface comes from redmine_gtt; true only when present.
    def base_capabilities(gtt_present)
      {
        geojson_read: gtt_present,
        geojson_write: gtt_present,
        spatial_filter_bbox: gtt_present,
        spatial_filter_distance: gtt_present
      }
    end

    # This plugin's contract endpoints: advertised iff their route is defined.
    def contract_capabilities
      CONTRACT_ROUTES.transform_values { |route_name| route_defined?(route_name) }
    end

    # Behaviours of existing endpoints (not new routes, so they can't be
    # route-detected). query_scoped_bundle: the bundle endpoints accept an
    # optional query_id and the all-projects bundle accepts none (project /
    # all-projects scope x optional saved query). A client must feature-detect
    # this before passing query_id, since an older server would silently ignore
    # it and return an unfiltered bundle.
    def behavior_capabilities
      { query_scoped_bundle: true }
    end

    def route_defined?(route_name)
      # url_helpers reflects every named route reliably; named_routes.key? does
      # not pick up plugin routes here (Redmine loads them into a way that
      # leaves that collection empty for our names).
      Rails.application.routes.url_helpers.respond_to?(:"#{route_name}_path")
    end
  end
end
