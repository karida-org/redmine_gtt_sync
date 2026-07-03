require File.expand_path('../../test_helper', __FILE__)
require 'ostruct'

class RedmineGttSyncIssueDocumentTest < ActiveSupport::TestCase
  setup do
    # build() reads User.current for the changeset permission gate; with empty
    # associations below the rich sections just come back empty. (Populated
    # sections are covered against real records in the controller test.)
    User.stubs(:current).returns(stub(allowed_to?: false))
  end

  def factory
    RGeo::Cartesian.preferred_factory(srid: 4326, has_z_coordinate: true)
  end

  # A lightweight stand-in for an Issue: the builder only reads attributes and
  # associations, so this avoids DB fixtures and keeps the test a pure unit.
  def fake_issue(geom: nil)
    issue = OpenStruct.new(
      id: 12,
      subject: 'Broken sign',
      description: 'A description',
      status: OpenStruct.new(id: 1, name: 'New'),
      tracker: OpenStruct.new(id: 2, name: 'Task'),
      project: OpenStruct.new(id: 3, identifier: 'field-survey', name: 'Field Survey'),
      geom: geom,
      lock_version: 4,
      updated_on: Time.utc(2026, 7, 2, 10, 0, 0),
      priority: OpenStruct.new(id: 2, name: 'Normal'),
      author: OpenStruct.new(id: 7, name: 'Dev'),
      assigned_to: OpenStruct.new(id: 8, name: 'Field Worker'),
      category: nil,
      fixed_version: nil,
      parent_id: nil,
      start_date: Date.new(2026, 7, 1),
      due_date: nil,
      done_ratio: 30,
      estimated_hours: nil,
      is_private: false,
      created_on: Time.utc(2026, 6, 1, 9, 0, 0),
      closed_on: nil,
      journals: [],
      relations: [],
      changesets: [],
      attachments: [],
      visible_custom_field_values: []
    )
    # These take a user arg, so they can't be plain OpenStruct readers; stub the
    # RBAC editing contract (safe_attribute_names + new_statuses_allowed_to).
    issue.stubs(:safe_attribute_names).returns(%w[subject description status_id geojson])
    issue.stubs(:new_statuses_allowed_to).returns(
      [OpenStruct.new(id: 1, name: 'New'), OpenStruct.new(id: 2, name: 'In Progress')]
    )
    # editable_custom_field_values(user) drives the per-field `writable` flag;
    # default to none editable (tests that check it override this).
    issue.stubs(:editable_custom_field_values).returns([])
    issue
  end

  def test_builds_identity_references_and_geometry
    issue = fake_issue(geom: factory.point(135.3, 34.7, 0.0))
    doc = RedmineGttSync::IssueDocument.build(issue, base_url: 'https://example.com/')

    assert_equal 'https://example.com/issues/12', doc['@id']
    assert_equal 'gtt:Issue', doc['@type']
    assert_equal 12, doc['identifier']
    assert_equal 'Broken sign', doc['subject']
    assert_equal 'https://example.com/issue_statuses/1', doc['status']['@id']
    assert_equal 'New', doc['status']['name']
    assert_equal 'https://example.com/trackers/2', doc['tracker']['@id']
    assert_equal 'Task', doc['tracker']['name']
    assert_equal 'https://example.com/projects/field-survey', doc['project']['@id']
    assert_equal 'Point', doc['geometry']['type']
    assert doc['asWKT'].start_with?('SRID=4326;'), doc['asWKT']
    assert_equal 4, doc['lock_version']
    assert doc['@context'].key?('geo'), 'context declares the GeoSPARQL prefix'
    # Core fields (reflection-confirmed) are carried.
    assert_equal 'Normal', doc['priority']['name']
    assert_equal 'https://example.com/users/7', doc['author']['@id']
    assert_equal 'Field Worker', doc['assigned_to']['name']
    assert_equal 30, doc['done_ratio']
    assert_equal false, doc['is_private']
    assert_equal '2026-07-01', doc['start_date']
    # Unset references compact out.
    refute doc.key?('category')
    refute doc.key?('fixed_version')
  end

  def test_issue_without_geometry_omits_geometry_keys
    doc = RedmineGttSync::IssueDocument.build(
      fake_issue(geom: nil), base_url: 'https://example.com'
    )
    refute doc.key?('geometry')
    refute doc.key?('asWKT')
    assert_equal 'https://example.com/issues/12', doc['@id']
  end

  def test_rich_sections_present_and_empty_without_data
    doc = RedmineGttSync::IssueDocument.build(fake_issue, base_url: 'https://example.com')
    # The sections are always present (stable shape) even with no data.
    assert_equal [], doc['journals']
    assert_equal [], doc['relations']
    assert_equal [], doc['changesets']
    assert_equal [], doc['attachments']
    assert_equal [], doc['custom_fields']
    assert doc['@context'].key?('journals'), 'context declares the new terms'
  end

  def test_editable_contract_carries_writable_fields_and_status_transitions
    doc = RedmineGttSync::IssueDocument.build(fake_issue, base_url: 'https://x')
    assert_equal %w[subject description status_id geojson], doc['editable']['fields']
    assert_equal(
      ['New', 'In Progress'],
      doc['editable']['status_transitions'].map { |s| s['name'] }
    )
  end

  def test_custom_field_values_carry_format_multiple_and_edit_metadata
    field = OpenStruct.new(
      id: 5, name: 'Severity', field_format: 'list', multiple: false,
      possible_values: %w[Low Medium High]
    )
    value = OpenStruct.new(custom_field: field, custom_field_id: 5, value: 'High')
    issue = fake_issue
    issue.visible_custom_field_values = [value]
    # This user may edit field 5, so it comes back writable with its options.
    issue.stubs(:editable_custom_field_values).returns([value])

    cf = RedmineGttSync::IssueDocument.build(issue, base_url: 'https://x')['custom_fields']
    assert_equal 1, cf.size
    assert_equal 5, cf[0]['id']
    assert_equal 'Severity', cf[0]['name']
    assert_equal 'list', cf[0]['field_format']
    assert_equal false, cf[0]['multiple']
    assert_equal 'High', cf[0]['value']
    assert_equal %w[Low Medium High], cf[0]['possible_values']
    assert_equal true, cf[0]['writable']
  end

  def test_custom_field_not_editable_is_marked_read_only
    field = OpenStruct.new(id: 5, name: 'Severity', field_format: 'list',
                           multiple: false, possible_values: [])
    value = OpenStruct.new(custom_field: field, custom_field_id: 5, value: 'High')
    issue = fake_issue
    issue.visible_custom_field_values = [value]
    # editable_custom_field_values is empty (the fake default), so not writable.
    cf = RedmineGttSync::IssueDocument.build(issue, base_url: 'https://x')['custom_fields']
    assert_equal false, cf[0]['writable']
  end
end
