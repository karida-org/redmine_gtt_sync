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

    # The managed public client QTask uses: Authorization Code + PKCE, loopback
    # redirect on QGIS's default OAuth port, no client secret.
    QTASK_APP_NAME = 'QTask'.freeze
    QTASK_REDIRECT_URI = 'http://127.0.0.1:7070/'.freeze

    module_function

    # Create or reconcile the public QTask OAuth application and return it, so an
    # admin can provision a correctly-configured client in one click instead of
    # hand-registering one. Idempotent: an existing public "QTask" app has its
    # redirect + scopes brought back in line (this is also how the scope list
    # stays current as it grows); never touches a confidential app of that name.
    def ensure_qtask_application
      app = Doorkeeper::Application.where(confidential: false)
                                   .find_or_initialize_by(name: QTASK_APP_NAME)
      app.redirect_uri = QTASK_REDIRECT_URI
      app.scopes = SCOPES.join(' ')
      app.confidential = false
      app.save!
      app
    end

    def authorize_url(base_url)
      "#{base_url.chomp('/')}/oauth/authorize"
    end

    def token_url(base_url)
      "#{base_url.chomp('/')}/oauth/token"
    end

    # The OAuth block for the capabilities payload. Doorkeeper is bundled in
    # RedMica/Redmine core, so these endpoints always exist. ``client_id`` is
    # included only when an admin has selected a public app to advertise (a
    # public PKCE client_id is not a secret); omitted otherwise so a client
    # falls back to asking the user for it.
    def advertisement(base_url, client_id: nil)
      ad = {
        authorize_url: authorize_url(base_url),
        token_url: token_url(base_url),
        scopes: SCOPES
      }
      ad[:client_id] = client_id if client_id.present?
      ad
    end
  end
end
