module RedmineGttSync
  # OAuth2 integration parameters advertised to clients (QTask for QGIS) via the
  # public capabilities probe, so a user setting up a connection never has to
  # know which scopes or endpoints to configure by hand.
  #
  # SCOPES is the single source of truth for the least-privilege scope set the
  # contract endpoints need. The OAuth application's allowlist (provisioned
  # server-side) should be a superset of this; keeping the constant here lets
  # provisioning derive from it and lets clients react when the list grows
  # (e.g. adding :add_issue_notes) without a client release.
  module OAuth
    # Ordered so the advertised list is stable across requests. Least privilege
    # for the QGIS sync: list/pick projects, read/create/edit issues, read GTT
    # styling, and pass the gtt_sync integration gate.
    SCOPES = %w[
      view_project
      search_project
      view_issues
      add_issues
      edit_issues
      view_gtt_settings
      use_gtt_sync
    ].freeze

    module_function

    def authorize_url(base_url)
      "#{base_url.chomp('/')}/oauth/authorize"
    end

    def token_url(base_url)
      "#{base_url.chomp('/')}/oauth/token"
    end

    # The OAuth block for the capabilities payload. Doorkeeper is bundled in
    # RedMica/Redmine core, so these endpoints always exist.
    def advertisement(base_url)
      {
        authorize_url: authorize_url(base_url),
        token_url: token_url(base_url),
        scopes: SCOPES
      }
    end
  end
end
