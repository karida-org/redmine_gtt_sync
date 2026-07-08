require File.expand_path('../../test_helper', __FILE__)

class RedmineGttSyncOAuthTest < ActiveSupport::TestCase
  def test_advertisement_includes_client_id_only_when_given
    base = 'https://demo.example.org'
    without = RedmineGttSync::OAuth.advertisement(base)
    with = RedmineGttSync::OAuth.advertisement(base, client_id: 'abc')
    refute without.key?(:client_id)
    assert_equal 'abc', with[:client_id]
    # A blank client_id is treated as absent.
    assert_not RedmineGttSync::OAuth.advertisement(base, client_id: '').key?(:client_id)
  end

  def test_advertisement_falls_back_to_full_scopes_without_a_resolvable_app
    base = 'https://demo.example.org'
    # No app advertised, and a client_id that resolves to no public app, both
    # advertise the full recommended set (manual-setup fallback).
    assert_equal(RedmineGttSync::OAuth::SCOPES,
                 RedmineGttSync::OAuth.advertisement(base)[:scopes])
    assert_equal(RedmineGttSync::OAuth::SCOPES,
                 RedmineGttSync::OAuth.advertisement(base, client_id: 'nope')[:scopes])
  end

  def test_advertisement_uses_the_apps_own_scopes_when_advertised
    # The app's allowlist is the source of truth: advertise the intersection of
    # what QTask uses and what the app permits, so the client requests exactly
    # what Doorkeeper will grant (no invalid_scope), and a narrowed app just
    # drops the corresponding scopes.
    narrowed = RedmineGttSync::OAuth::SCOPES - %w[delete_issues edit_own_issue_notes]
    app = Doorkeeper::Application.create!(
      name: 'QTask narrowed', redirect_uri: 'http://127.0.0.1:7070/',
      scopes: narrowed.join(' '), confidential: false
    )
    advertised = RedmineGttSync::OAuth.advertisement(
      'https://demo.example.org', client_id: app.uid
    )[:scopes]
    assert_equal narrowed, advertised
    assert_not_includes advertised, 'delete_issues'
    # Advertised scopes never exceed what the app permits.
    assert_empty(advertised - app.scopes.to_a.map(&:to_s))
  end

  def test_advertisement_ignores_app_scopes_outside_the_qtask_set
    # An admin expanding the app with unrelated scopes doesn't bloat the request:
    # only scopes QTask actually uses are advertised.
    app = Doorkeeper::Application.create!(
      name: 'QTask expanded', redirect_uri: 'http://127.0.0.1:7070/',
      scopes: (RedmineGttSync::OAuth::SCOPES + %w[view_calendar]).join(' '),
      confidential: false
    )
    advertised = RedmineGttSync::OAuth.advertisement(
      'https://demo.example.org', client_id: app.uid
    )[:scopes]
    assert_equal RedmineGttSync::OAuth::SCOPES, advertised
    assert_not_includes advertised, 'view_calendar'
  end

  def test_scope_status_splits_granted_and_ungranted_against_the_app
    narrowed = RedmineGttSync::OAuth::SCOPES - %w[delete_issues]
    app = Doorkeeper::Application.create!(
      name: 'QTask status', redirect_uri: 'http://127.0.0.1:7070/',
      scopes: narrowed.join(' '), confidential: false
    )
    status = RedmineGttSync::OAuth.scope_status(app.uid)
    assert_equal narrowed, status[:granted]
    assert_equal %w[delete_issues], status[:ungranted]
    # No app -> everything granted, nothing ungranted.
    none = RedmineGttSync::OAuth.scope_status(nil)
    assert_equal RedmineGttSync::OAuth::SCOPES, none[:granted]
    assert_empty none[:ungranted]
  end

  def test_qgis_oauth2_config_scopes_follow_the_app
    narrowed = RedmineGttSync::OAuth::SCOPES - %w[delete_issues]
    app = Doorkeeper::Application.create!(
      name: 'QTask cfg', redirect_uri: 'http://127.0.0.1:7070/',
      scopes: narrowed.join(' '), confidential: false
    )
    cfg = RedmineGttSync::OAuth.qgis_oauth2_config('https://demo.example.org', app.uid)
    # The downloadable config must request only what the app grants, or importing
    # it hits invalid_scope for a narrowed app.
    assert_equal narrowed.join(' '), cfg[:scope]
    assert_not_includes cfg[:scope].split, 'delete_issues'
  end

  def test_qgis_oauth2_config_persists_token_and_uses_pkce
    cfg = RedmineGttSync::OAuth.qgis_oauth2_config('https://demo.example.org', 'cid')
    # Persist across restarts (matches QTask's default) so an imported config
    # doesn't re-authorize in the browser every launch.
    assert_equal true, cfg[:persistToken]
    # Authorization Code + PKCE, Bearer header, public client (no secret).
    assert_equal 3, cfg[:grantFlow]
    assert_equal 0, cfg[:accessMethod]
    assert_nil cfg[:clientSecret]
    assert_equal 'cid', cfg[:clientId]
    assert_equal 'https://demo.example.org/oauth/authorize', cfg[:requestUrl]
  end

  def test_ensure_qtask_application_creates_a_public_pkce_app
    app = RedmineGttSync::OAuth.ensure_qtask_application
    assert app.persisted?
    assert_not app.confidential?
    assert_equal RedmineGttSync::OAuth::QTASK_REDIRECT_URI, app.redirect_uri
    assert_equal RedmineGttSync::OAuth::SCOPES.join(' '), app.scopes.to_s
  end

  def test_ensure_qtask_application_is_idempotent_and_reconciles
    first = RedmineGttSync::OAuth.ensure_qtask_application
    # Drift redirect + scopes, then re-run: same record, values restored.
    first.update!(scopes: 'view_issues', redirect_uri: 'http://127.0.0.1:9999/')
    second = RedmineGttSync::OAuth.ensure_qtask_application
    assert_equal first.id, second.id
    assert_equal RedmineGttSync::OAuth::SCOPES.join(' '), second.scopes.to_s
    assert_equal RedmineGttSync::OAuth::QTASK_REDIRECT_URI, second.redirect_uri
  end

  def test_ensure_ignores_a_confidential_app_of_the_same_name
    confidential = Doorkeeper::Application.create!(
      name: RedmineGttSync::OAuth::QTASK_APP_NAME,
      redirect_uri: 'http://127.0.0.1:7070/', scopes: 'view_issues', confidential: true
    )
    app = RedmineGttSync::OAuth.ensure_qtask_application
    assert_not_equal confidential.id, app.id
    assert_not app.confidential?
  end
end
