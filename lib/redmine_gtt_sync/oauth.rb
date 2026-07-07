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
    # for the QGIS sync: list/pick projects, read/create/edit issues, work with
    # notes (public and private), read GTT styling, and pass the gtt_sync
    # integration gate.
    #
    # Notes need explicit scopes: over OAuth, Redmine gates permissions by the
    # token's scopes even for an admin, so edit_issues alone only lets a *public*
    # note through - add_issue_notes/view_private_notes/set_notes_private are
    # required for the panel's note features (add, see, and mark private). Adding
    # a scope here widens the OAuth app and the advertised list; existing
    # connections re-authorize when scope drift is detected.
    SCOPES = %w[
      view_project
      search_project
      view_issues
      add_issues
      edit_issues
      set_issues_private
      add_issue_notes
      view_private_notes
      set_notes_private
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

    # The QGIS OAuth2 config for this instance, keyed exactly as QGIS's auth
    # import/export uses it. Served as a downloadable file from the Connect QGIS
    # page so a user can import it instead of hand-filling QGIS's OAuth2 editor.
    # Mirrors what QTask generates programmatically (public PKCE client, Bearer,
    # loopback redirect, no secret). grantFlow 3 = Authorization Code + PKCE;
    # accessMethod 0 = Bearer header.
    def qgis_oauth2_config(base_url, client_id)
      {
        version: 1,
        configType: 1,
        grantFlow: 3,
        accessMethod: 0,
        requestUrl: authorize_url(base_url),
        tokenUrl: token_url(base_url),
        redirectHost: '127.0.0.1',
        redirectPort: 7070,
        clientId: client_id,
        clientSecret: nil,
        scope: SCOPES.join(' '),
        # Persist the token in QGIS's auth database so an imported connection
        # stays signed in across restarts (matches QTask's built-in default);
        # otherwise the token is session-only and re-authorizes every launch.
        persistToken: true,
        requestTimeout: 30
      }
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
