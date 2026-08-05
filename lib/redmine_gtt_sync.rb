# frozen_string_literal: true

# Namespace root for the plugin's library code. Each concern lives in its own
# file under lib/redmine_gtt_sync/; only genuinely shared helpers belong here.
module RedmineGttSync
  # The instance's canonical origin (from Redmine's own settings, not the
  # request host), so IRIs and advertised OAuth endpoints are stable regardless
  # of how a request arrived (proxy, tunnel, container-internal hostname).
  # Single definition: the controllers and the capabilities probe all delegate
  # here so the concept cannot drift.
  def self.canonical_base_url
    "#{Setting.protocol}://#{Setting.host_name}"
  end
end
