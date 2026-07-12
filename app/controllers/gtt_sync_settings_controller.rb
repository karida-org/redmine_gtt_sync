# Admin-only actions behind the plugin settings screen. Kept separate from
# GttSyncController (the public/authenticated integration contract) because this
# manages server configuration, not the contract itself.
class GttSyncSettingsController < ApplicationController
  before_action :require_admin

  # Provision (or reconcile) the public QTask OAuth application and select it as
  # the advertised app, so an admin doesn't have to hand-register a client.
  def create_oauth_application
    app = RedmineGttSync::OAuth.ensure_qtask_application
    Setting.plugin_redmine_gtt_sync = Setting.plugin_redmine_gtt_sync.merge(
      'oauth_application_uid' => app.uid
    )
    flash[:notice] = l(:notice_gtt_sync_oauth_application_created)
  rescue StandardError => e
    flash[:error] = l(:error_gtt_sync_oauth_application_failed, message: e.message)
  ensure
    redirect_to plugin_settings_path(id: 'redmine_gtt_sync')
  end
end
