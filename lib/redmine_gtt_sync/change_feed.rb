# frozen_string_literal: true

module RedmineGttSync
  # Delta feed for efficient resync (#7): the issues changed since a cursor,
  # so a client (QTask, an offline QField import) refreshes incrementally
  # instead of re-fetching a whole bundle.
  #
  # Correctness model, in client terms:
  # - The cursor is a (updated_on, id) position, not a bare timestamp. Paging
  #   uses a strict tuple comparison, so many rows sharing one second can
  #   neither be lost between pages nor loop forever on one page.
  # - Rows younger than SETTLE_LAG_SECONDS are held back, and the cursor never
  #   advances past that horizon. A transaction that commits "in the past"
  #   (updated_on set before a slow commit) therefore still gets picked up by
  #   a later poll instead of being skipped forever.
  # - Delivery is at-least-once at the margins: a client must apply entries
  #   idempotently by issue id (last write wins locally).
  # - Deletions are NOT in the feed. Redmine hard-deletes issues, and an issue
  #   can also simply leave the user's visibility (moved to a private project),
  #   which no tombstone could represent. Reconciliation instead: request
  #   known_ids and drop local issues missing from it.
  module ChangeFeed
    # Maximum entries per response; a client follows `more` and polls again.
    PAGE_LIMIT = 200

    # How long a row must have "settled" before the feed serves it. Redmine
    # sets updated_on in the application just before commit, so this only
    # needs to exceed a plausible slow-commit window.
    SETTLE_LAG_SECONDS = 10

    # A position in the feed. `id` breaks ties between rows updated in the
    # same instant (databases without sub-second datetime precision make such
    # ties common).
    Cursor = Struct.new(:updated_on, :id)

    module_function

    # Parse a `since` value into a Cursor, or nil when malformed. Accepts the
    # token this feed returned (`<iso8601>/<id>`) or a plain ISO 8601 time for
    # a first sync (which reads as "everything after that instant").
    def parse_cursor(raw)
      value = raw.to_s.strip
      return nil if value.empty?

      time_part, id_part = value.split('/', 2)
      id = id_part.nil? ? 0 : Integer(id_part, exception: false)
      return nil if id.nil? || id.negative?

      Cursor.new(Time.iso8601(time_part), id)
    rescue ArgumentError
      nil
    end

    def encode_cursor(cursor)
      "#{cursor.updated_on.utc.iso8601(6)}/#{cursor.id}"
    end

    # Build the feed payload. +scope+ must already be permission-scoped by the
    # controller (Issue.visible plus the use_gtt_sync project gate); +user+ is
    # the acting user the per-entry editable flag is resolved for. +limit+ is
    # parameterized for tests; the endpoint always serves PAGE_LIMIT.
    def build(scope, cursor, user:, include_known_ids: false, limit: PAGE_LIMIT)
      rows = page(scope, cursor, limit)
      more = rows.size > limit
      rows = rows.first(limit)
      preload(rows)

      last = rows.last
      payload = {
        'issues' => rows.map { |issue| entry(issue, user) },
        # An empty page returns the input cursor unchanged: there is nothing
        # safe to advance past (the horizon is still unsettled territory).
        'next_since' => encode_cursor(last ? Cursor.new(last.updated_on, last.id) : cursor),
        'more' => more
      }
      # All issue ids in scope, for deletion/visibility reconciliation (see
      # the module comment). Opt-in: plain integers, but potentially many.
      payload['known_ids'] = scope.order(:id).ids if include_known_ids
      payload
    end

    # One page of settled rows after the cursor, in feed order, fetching one
    # extra row to learn whether more remain.
    def page(scope, cursor, limit)
      table = Issue.table_name
      scope
        .where(
          "#{table}.updated_on > :time OR (#{table}.updated_on = :time AND #{table}.id > :id)",
          time: cursor.updated_on, id: cursor.id
        )
        .where("#{table}.updated_on <= ?", SETTLE_LAG_SECONDS.seconds.ago)
        .order(:updated_on, :id)
        .limit(limit + 1)
        .to_a
    end

    # The bundle summary plus the geometry itself, so a client can update its
    # local feature without a second request. No geometry key = the issue is
    # unplaced (matching the bundle's unplaced entries, which the summary
    # shape comes from).
    def entry(issue, user)
      summary = ProjectBundle.summary(issue, user)
      geojson = issue.geom && Geometry.to_geojson(issue.geom)
      geojson ? summary.merge('geometry' => geojson) : summary
    end

    def preload(rows)
      ActiveRecord::Associations::Preloader.new(
        records: rows, associations: ProjectBundle::SUMMARY_ASSOCIATIONS
      ).call
    end
  end
end
