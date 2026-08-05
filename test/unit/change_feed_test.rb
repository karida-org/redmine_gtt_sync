# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

class RedmineGttSyncChangeFeedTest < ActiveSupport::TestCase
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles,
           :enabled_modules, :trackers, :issue_statuses, :issues, :enumerations

  # -- cursor token ----------------------------------------------------------

  def test_cursor_roundtrip
    cursor = RedmineGttSync::ChangeFeed::Cursor.new(
      Time.utc(2026, 8, 5, 12, 34, 56.789), 42
    )
    parsed = RedmineGttSync::ChangeFeed.parse_cursor(
      RedmineGttSync::ChangeFeed.encode_cursor(cursor)
    )
    assert_equal cursor.updated_on.to_f, parsed.updated_on.to_f
    assert_equal 42, parsed.id
  end

  def test_plain_iso_time_is_a_valid_first_cursor
    parsed = RedmineGttSync::ChangeFeed.parse_cursor('2026-08-05T00:00:00Z')
    assert_equal Time.utc(2026, 8, 5), parsed.updated_on
    assert_equal 0, parsed.id
  end

  def test_malformed_cursors_parse_to_nil
    [nil, '', '   ', 'abc', '2026-99-99T00:00:00Z',
     '2026-08-05T00:00:00Z/x', '2026-08-05T00:00:00Z/-1', '/5'].each do |raw|
      assert_nil RedmineGttSync::ChangeFeed.parse_cursor(raw), raw.inspect
    end
  end

  # -- paging ----------------------------------------------------------------

  def epoch_cursor
    RedmineGttSync::ChangeFeed::Cursor.new(Time.utc(2000, 1, 1), 0)
  end

  def test_pages_advance_through_same_second_rows_without_loss_or_loop
    # Three rows sharing one settled instant: the id tiebreak must page
    # through them - a bare-timestamp cursor would either drop the rest of
    # the second or serve the same page forever.
    tied = Time.utc(2026, 1, 1, 12, 0, 0)
    ids = [1, 2, 3]
    ids.each { |id| Issue.find(id).update_column(:updated_on, tied) }
    scope = Issue.where(id: ids)
    admin = User.find(1)

    first = RedmineGttSync::ChangeFeed.build(
      scope, epoch_cursor, user: admin, limit: 2
    )
    assert_equal([1, 2], first['issues'].map { |i| i['id'] })
    assert first['more']

    second = RedmineGttSync::ChangeFeed.build(
      scope, RedmineGttSync::ChangeFeed.parse_cursor(first['next_since']),
      user: admin, limit: 2
    )
    assert_equal([3], second['issues'].map { |i| i['id'] })
    assert_not second['more']

    third = RedmineGttSync::ChangeFeed.build(
      scope, RedmineGttSync::ChangeFeed.parse_cursor(second['next_since']),
      user: admin, limit: 2
    )
    assert_equal [], third['issues']
    # An empty page hands the same cursor back; the client just polls again.
    assert_equal second['next_since'], third['next_since']
  end

  def test_unsettled_rows_are_held_back_and_the_cursor_does_not_pass_them
    # A future timestamp is unsettled by construction, so the test cannot
    # flake by outrunning the settle lag on a slow run.
    Issue.find(1).update_column(:updated_on, Time.current + 1.hour)
    scope = Issue.where(id: 1)

    feed = RedmineGttSync::ChangeFeed.build(scope, epoch_cursor, user: User.find(1))
    assert_equal [], feed['issues']
    assert_equal RedmineGttSync::ChangeFeed.encode_cursor(epoch_cursor),
                 feed['next_since']
  end

  def test_entry_is_the_bundle_summary_with_no_geometry_key_when_unplaced
    Issue.find(1).update_column(:updated_on, Time.utc(2026, 1, 1))
    feed = RedmineGttSync::ChangeFeed.build(
      Issue.where(id: 1), epoch_cursor, user: User.find(1)
    )
    entry = feed['issues'].first
    assert_equal 1, entry['id']
    assert entry.key?('lock_version')
    assert entry.key?('editable')
    # Fixture issues carry no geometry: no geometry key means unplaced.
    assert_not entry.key?('geometry')
  end

  def test_known_ids_lists_the_whole_scope_when_requested
    scope = Issue.where(project_id: 1)
    feed = RedmineGttSync::ChangeFeed.build(
      scope, epoch_cursor, user: User.find(1), include_known_ids: true
    )
    assert_equal scope.order(:id).ids, feed['known_ids']

    without = RedmineGttSync::ChangeFeed.build(scope, epoch_cursor, user: User.find(1))
    assert_not without.key?('known_ids')
  end
end
