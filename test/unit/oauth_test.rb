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
