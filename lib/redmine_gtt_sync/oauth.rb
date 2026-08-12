# frozen_string_literal: true

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
    # for the QTask (QGIS) client: list/pick projects, edit a project's boundary,
    # read/create/edit/delete issues, work with notes (add, edit/delete,
    # private), set the issue Private flag, read GTT styling, and pass the
    # gtt_sync integration gate.
    #
    # Over OAuth, Redmine gates permissions by the token's scopes even for an
    # admin (effective = role permissions & token scopes, see
    # Role#allowed_permissions), so each write feature needs its scope:
    # - edit_project gates the project-boundary write (QTask's PUT
    #   /projects/:id.json with the redmine_gtt geojson safe-attribute); without
    #   it a boundary save is refused over OAuth even for a user who may edit the
    #   project. It only lifts the OAuth ceiling - the per-user edit_project
    #   permission is still the floor, so a user without it is still denied.
    # - edit_issues alone only lets a *public* note through, so
    #   add_issue_notes/view_private_notes/set_notes_private are required for the
    #   panel's note features (add, see, and mark private), and
    #   edit_issue_notes/edit_own_issue_notes for editing or clearing
    #   (= deleting) a note via the stock PUT /journals/:id write.
    # - delete_issues gates issue deletion.
    # Every scope here maps to a real Redmine permission (Doorkeeper scopes =
    # AccessControl.permissions). Adding a scope widens the OAuth app and the
    # advertised list; existing connections re-authorize on scope drift.
    SCOPES = %w[
      view_project
      search_project
      edit_project
      view_issues
      add_issues
      edit_issues
      delete_issues
      set_issues_private
      add_issue_notes
      edit_issue_notes
      edit_own_issue_notes
      view_private_notes
      set_notes_private
      view_gtt_settings
      use_gtt_sync
    ].freeze

    # The managed public client QTask uses: Authorization Code + PKCE, loopback
    # redirect on QGIS's default OAuth port, no client secret.
    QTASK_APP_NAME = 'QTask'
    QTASK_REDIRECT_URI = 'http://127.0.0.1:7070/'

    # The managed public client the Georeport mobile app uses: Authorization
    # Code + PKCE with a custom-scheme redirect (a phone cannot listen on a
    # loopback port the way a desktop can), no client secret. The provisioned
    # app record stays the source of truth: an admin who needs a different or
    # additional redirect (for example an app-link URL) can edit the
    # application, and the probe advertises whatever the record holds.
    MOBILE_APP_NAME = 'Georeport'
    MOBILE_REDIRECT_URI = 'georeport://oauth/callback'

    module_function

    # Create or reconcile the public QTask OAuth application and return it, so an
    # admin can provision a correctly-configured client in one click instead of
    # hand-registering one. Idempotent: an existing public "QTask" app has its
    # redirect + scopes brought back in line (this is also how the scope list
    # stays current as it grows); never touches a confidential app of that name.
    def ensure_qtask_application
      ensure_public_application(QTASK_APP_NAME, QTASK_REDIRECT_URI)
    end

    # The mobile counterpart of ensure_qtask_application, with the same
    # idempotent reconcile semantics.
    def ensure_mobile_application
      ensure_public_application(MOBILE_APP_NAME, MOBILE_REDIRECT_URI)
    end

    def ensure_public_application(name, redirect_uri)
      app = Doorkeeper::Application.where(confidential: false)
                                   .find_or_initialize_by(name: name)
      app.redirect_uri = redirect_uri
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
        # Effective scopes for this app, not the raw SCOPES: a downloaded config
        # must request only what the app grants, or importing it hits the same
        # invalid_scope error when an admin has narrowed the app.
        scope: advertised_scopes(client_id).join(' '),
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
    #
    # The top-level ``client_id`` and ``scopes`` describe the desktop (QTask)
    # app and predate multi-client advertisement; released QTask versions read
    # them, so they stay. New clients should read ``clients`` instead: one
    # entry per advertised app kind, each carrying its client_id, the redirect
    # URIs from the app record, and the scopes that app actually grants.
    def advertisement(base_url, client_id: nil, mobile_client_id: nil)
      ad = {
        authorize_url: authorize_url(base_url),
        token_url: token_url(base_url),
        scopes: advertised_scopes(client_id)
      }
      ad[:client_id] = client_id if client_id.present?
      clients = {
        desktop: client_entry(client_id),
        mobile: client_entry(mobile_client_id)
      }.compact
      ad[:clients] = clients if clients.any?
      ad
    end

    # A per-client advertisement entry, resolved from the application record so
    # admin customizations (extra redirect URIs, a narrowed scope allowlist)
    # are exactly what clients see. Public apps only; anything else is omitted.
    def client_entry(uid)
      return nil if uid.blank?

      app = Doorkeeper::Application.where(confidential: false).find_by(uid: uid)
      return nil unless app

      {
        client_id: app.uid,
        # Doorkeeper stores multiple redirect URIs whitespace-separated.
        redirect_uris: app.redirect_uri.to_s.split,
        scopes: SCOPES & app.scopes.to_a.map(&:to_s)
      }
    end

    # Split the QTask scope set against a managed app's allowlist:
    # { granted: SCOPES the app permits, ungranted: SCOPES it doesn't }.
    # Single source for both the advertised scopes and the settings-page status,
    # so they can't drift. When a managed public app is advertised, `granted`
    # is `SCOPES & app.scopes` (order preserved); the client then requests
    # exactly what Doorkeeper will grant, so an authorize can never fail with
    # invalid_scope (the failure mode when the app's allowlist and the requested
    # scopes drift), and an admin who narrows the app's scopes simply gates the
    # matching QTask features off - the app's allowlist is the source of truth.
    # Falls back to the full recommended set (all granted) when no app is
    # advertised (manual setup) or the client_id can't be resolved.
    def scope_status(client_id)
      return { granted: SCOPES, ungranted: [] } if client_id.blank?

      app = Doorkeeper::Application.where(confidential: false).find_by(uid: client_id)
      return { granted: SCOPES, ungranted: [] } unless app

      permitted = app.scopes.to_a.map(&:to_s)
      { granted: SCOPES & permitted, ungranted: SCOPES - permitted }
    end

    # The scopes to advertise, i.e. what the client will request at authorize
    # time = the scopes the advertised app actually grants.
    def advertised_scopes(client_id)
      scope_status(client_id)[:granted]
    end
  end
end
