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
    OpenStruct.new(
      id: 12,
      subject: 'Broken sign',
      description: 'A description',
      status: OpenStruct.new(id: 1, name: 'New'),
      tracker: OpenStruct.new(id: 2, name: 'Task'),
      project: OpenStruct.new(id: 3, identifier: 'field-survey', name: 'Field Survey'),
      geom: geom,
      lock_version: 4,
      updated_on: Time.utc(2026, 7, 2, 10, 0, 0),
      journals: [],
      relations: [],
      changesets: [],
      attachments: []
    )
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
    assert doc['@context'].key?('journals'), 'context declares the new terms'
  end
end
