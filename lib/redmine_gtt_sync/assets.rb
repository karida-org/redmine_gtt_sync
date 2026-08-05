# frozen_string_literal: true

require 'fileutils'
require 'securerandom'

module RedmineGttSync
  # Serves the plugin's assets/ under public/plugin_assets/. This stack does
  # not auto-mirror plugin assets (no boot-time mirror, and assets:precompile
  # skips plugin_assets), so the plugin links its own at boot - mirroring
  # redmine_canvas_gantt. Symlink when possible; fall back to copying where
  # symlinks are unavailable (e.g. a Docker volume mount).
  #
  # The source defaults to this plugin's own assets/ directory (derived from
  # this file's location, so a differently named plugin directory - packaged,
  # vendored, checked out elsewhere - still resolves). The destination uses the
  # plugin id, which is what javascript_include_tag(plugin: 'redmine_gtt_sync')
  # expects under public/plugin_assets/.
  module Assets
    PLUGIN_ID = 'redmine_gtt_sync'

    module_function

    # Mirror +source+ to +destination+, best-effort: any failure is logged and
    # swallowed so an asset problem can never take the whole instance down.
    def mirror(source: default_source, destination: default_destination)
      return unless File.directory?(source)

      FileUtils.mkdir_p(File.dirname(destination))
      if File.symlink?(destination)
        refresh_symlink(source, destination)
      elsif File.exist?(destination)
        # Keep copied assets in sync when a symlink is unavailable.
        copy(source, destination)
      else
        link_or_copy(source, destination)
      end
    rescue StandardError => e
      Rails.logger.warn("#{PLUGIN_ID}: failed to link plugin assets: #{e.message}") if defined?(Rails)
    end

    def default_source
      File.expand_path('../../assets', __dir__)
    end

    def default_destination
      Rails.root.join('public', 'plugin_assets', PLUGIN_ID).to_s
    end

    # Refresh only when the link resolves elsewhere; compare real paths so a
    # symlinked plugin directory doesn't trigger a needless relink. Removing
    # the link then re-linking falls back to a copy if linking is disallowed,
    # so a symlink-hostile mount can't strand the destination empty.
    def refresh_symlink(source, destination)
      current = begin
        File.realpath(destination)
      rescue StandardError
        nil
      end
      desired = begin
        File.realpath(source)
      rescue StandardError
        source
      end
      return if current == desired

      FileUtils.rm_f(destination)
      link_or_copy(source, destination)
    end

    # Symlink into place, falling back to a copy where symlink creation is
    # disallowed. Assumes the destination path is already clear.
    def link_or_copy(source, destination)
      FileUtils.ln_s(source, destination)
    rescue Errno::EPERM, Errno::EACCES
      copy(source, destination)
    end

    # Copy assets into place: stage a full copy in a uniquely named directory,
    # then swap it in, so a failed or partial copy never leaves a half-populated
    # (JS-404ing) destination, and concurrent boots (a clustered deploy sharing
    # the volume) do not clobber each other's in-progress staging. A random
    # token (not just the pid, which can collide across replicas sharing the
    # volume) keeps concurrent boots on distinct staging dirs. Best-effort: a
    # lost swap race self-heals on the next boot.
    def copy(source, destination)
      staged = "#{destination}.staged.#{SecureRandom.hex(8)}"
      FileUtils.rm_rf(staged)
      begin
        FileUtils.cp_r(source, staged)
        FileUtils.rm_rf(destination)
        FileUtils.mv(staged, destination)
      ensure
        FileUtils.rm_rf(staged)
      end
    end
  end
end
