# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../app/controllers/gtt_sync_controller'

# The live user location contract (issue #93): publishing one's own current
# location, reading project members' latest locations behind a dedicated
# permission, and the capability flags. Permissions are the real Redmine RBAC
# (no stubs).
#
# Fixture cast: project 1 (eCookbook, public), user 2 (jsmith, member via
# role 1), user 3 (dlopper, member of project 1 via role 2).
# Tests arrange geometry columns directly (update_columns); that is fixture
# setup, not application behavior worth validating.
class GttSyncUserLocationsTest < ActionController::TestCase
  tests GttSyncController

  fixtures :projects, :users, :email_addresses, :roles, :members,
           :member_roles, :enabled_modules

  setup do
    project = Project.find(1)
    project.enabled_module_names = project.enabled_module_names | ['gtt_sync']
    @request.session[:user_id] = 2 # jsmith, member of project 1 via role 1
  end

  def grant(*permissions)
    Role.find(1).update!(permissions: %i[view_issues use_gtt_sync] + permissions)
    User.current = nil # drop Redmine's per-request permission memoization
  end

  def point(lon, lat)
    { 'type' => 'Point', 'coordinates' => [lon, lat] }
  end

  # --- publishing ---

  test 'publishes the caller own location and stamps last_heard' do
    grant

    post :publish_location, params: { location: point(135.2, 34.7) }

    assert_response :success
    body = response.parsed_body
    assert_equal 2, body.dig('user', 'id')
    assert_equal [135.2, 34.7], body.dig('location', 'coordinates')
    assert_not_nil body['last_heard']
    assert_not_nil User.find(2).geom_updated_on
  end

  test 'accepts a Feature wrapping a Point' do
    grant

    post :publish_location, params: {
      location: { 'type' => 'Feature', 'geometry' => point(1.5, 2.5),
                  'properties' => {} }
    }

    assert_response :success
    assert_equal [1.5, 2.5], response.parsed_body.dig('location', 'coordinates')
  end

  test 'a later publish replaces the previous point, keeping no history' do
    grant
    post :publish_location, params: { location: point(1.0, 2.0) }
    first_stamp = User.find(2).geom_updated_on

    travel_to(1.minute.from_now) do
      post :publish_location, params: { location: point(3.0, 4.0) }
    end

    assert_response :success
    user = User.find(2)
    assert_equal [3.0, 4.0], response.parsed_body.dig('location', 'coordinates')
    assert user.geom_updated_on > first_stamp
  end

  test 'rejects a non-point geometry' do
    grant

    post :publish_location, params: {
      location: { 'type' => 'LineString', 'coordinates' => [[1, 2], [3, 4]] }
    }

    assert_response :unprocessable_entity
    assert_nil User.find(2).geom_updated_on
  end

  test 'rejects coordinates out of range' do
    grant

    post :publish_location, params: { location: point(999, 34) }

    assert_response :unprocessable_entity
    assert_nil User.find(2).geom_updated_on
  end

  test 'publishing does not touch the profile updated_on' do
    grant
    before = User.find(2).updated_on

    travel_to(1.minute.from_now) do
      post :publish_location, params: { location: point(1.0, 2.0) }
    end

    assert_response :success
    assert_equal before.to_i, User.find(2).updated_on.to_i
  end

  # --- reading ---

  test 'refuses the member list without the dedicated permission' do
    grant # use_gtt_sync only: publishing is allowed, reading others is not

    get :user_locations, params: { id: 1 }

    assert_response :forbidden
  end

  test 'lists members with a location once the permission is granted' do
    grant(:view_user_locations)
    User.find(2).update_columns(geom: 'SRID=4326;POINT(1 2)',
                                geom_updated_on: Time.current)
    User.find(3).update_columns(geom: 'SRID=4326;POINT(3 4)',
                                geom_updated_on: Time.current)

    get :user_locations, params: { id: 1 }

    assert_response :success
    ids = response.parsed_body['locations'].map { |entry| entry.dig('user', 'id') }
    assert_includes ids, 2
    assert_includes ids, 3
  end

  test 'omits members who never published a location' do
    grant(:view_user_locations)
    User.find(2).update_columns(geom: 'SRID=4326;POINT(1 2)',
                                geom_updated_on: Time.current)
    User.find(3).update_columns(geom: nil, geom_updated_on: nil)

    get :user_locations, params: { id: 1 }

    assert_response :success
    ids = response.parsed_body['locations'].map { |entry| entry.dig('user', 'id') }
    assert_includes ids, 2
    assert_not_includes ids, 3
  end

  test 'a project without the module is refused' do
    grant(:view_user_locations)
    project = Project.find(1)
    project.enabled_module_names = project.enabled_module_names - ['gtt_sync']

    get :user_locations, params: { id: 1 }

    assert_response :forbidden
  end

  test 'an unknown project is a 404, not a leak' do
    grant(:view_user_locations)

    get :user_locations, params: { id: 999_999 }

    assert_response :not_found
  end

  # --- capabilities ---

  test 'advertises both location capabilities' do
    get :capabilities

    capabilities = response.parsed_body['capabilities']
    assert_equal true, capabilities['user_location_publish']
    assert_equal true, capabilities['user_locations']
  end

  test 'the location read scope is offered to OAuth clients' do
    assert_includes RedmineGttSync::OAuth::SCOPES, 'view_user_locations'
  end

  # --- serialization unit level ---

  test 'a location that was never published reports an unknown last_heard' do
    User.find(2).update_columns(geom: 'SRID=4326;POINT(1 2)',
                                geom_updated_on: nil)

    hash = RedmineGttSync::UserLocations.location_hash(User.find(2))

    assert_equal [1.0, 2.0], hash.dig('location', 'coordinates')
    assert_nil hash['last_heard']
  end

  test 'extract_point accepts both shapes and refuses everything else' do
    extract = RedmineGttSync::UserLocations.method(:extract_point)

    assert_equal [1.0, 2.0], extract.call(point(1, 2))
    assert_equal [1.0, 2.0], extract.call('type' => 'Feature',
                                          'geometry' => point(1, 2))
    # Form-encoded requests carry coordinates as numeric strings.
    assert_equal [1.5, 2.5], extract.call('type' => 'Point',
                                          'coordinates' => %w[1.5 2.5])
    assert_nil extract.call('type' => 'Point', 'coordinates' => %w[a b])
    assert_nil extract.call('type' => 'Point', 'coordinates' => [1])
    assert_nil extract.call('type' => 'Polygon', 'coordinates' => [])
    assert_nil extract.call('nonsense')
    assert_nil extract.call(nil)
  end
end
