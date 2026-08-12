# frozen_string_literal: true

# Admin-only actions behind the plugin settings screen. Kept separate from
# GttSyncController (the public/authenticated integration contract) because this
# manages server configuration, not the contract itself.
class GttSyncSettingsController < ApplicationController
  before_action :require_admin

  # Provision (or reconcile) the public QTask OAuth application and select it as
  # the advertised app, so an admin doesn't have to hand-register a client.
  def create_oauth_application
    provision_and_select('oauth_application_uid',
                         :notice_gtt_sync_oauth_application_created) do
      RedmineGttSync::OAuth.ensure_qtask_application
    end
  end

  # The mobile counterpart: provision (or reconcile) the public Georeport
  # mobile application and select it for the probe's mobile advertisement.
  def create_mobile_oauth_application
    provision_and_select('oauth_mobile_application_uid',
                         :notice_gtt_sync_mobile_oauth_application_created) do
      RedmineGttSync::OAuth.ensure_mobile_application
    end
  end

  private

  def provision_and_select(setting_key, notice_key)
    app = yield
    Setting.plugin_redmine_gtt_sync = Setting.plugin_redmine_gtt_sync.merge(
      setting_key => app.uid
    )
    flash[:notice] = l(notice_key)
  rescue StandardError => e
    flash[:error] = l(:error_gtt_sync_oauth_application_failed, message: e.message)
  ensure
    redirect_to plugin_settings_path(id: 'redmine_gtt_sync')
  end
end
