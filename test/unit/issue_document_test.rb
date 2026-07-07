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
    # Issue-level action permissions also take a user arg; default to allowed
    # (tests that check gating override these).
    issue.stubs(:deletable?).returns(true)
    issue.stubs(:notes_addable?).returns(true)
    # editable_custom_field_values(user) drives the per-field `writable` flag;
    # default to none editable (tests that check it override this).
    issue.stubs(:editable_custom_field_values).returns([])
    issue
  end

  # A lightweight stand-in for a visible journal note.
  def fake_journal(notes:, editable:, id: 1)
    journal = OpenStruct.new(
      id: id,
      user: OpenStruct.new(id: 7, name: 'Dev'),
      created_on: Time.utc(2026, 7, 2, 10, 0, 0),
      notes: notes,
      private_notes: false
    )
    journal.stubs(:visible?).returns(true)
    journal.stubs(:editable_by?).returns(editable)
    journal.stubs(:visible_details).returns([])
    journal
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

  def test_editable_contract_advertises_delete_and_add_notes_permissions
    doc = RedmineGttSync::IssueDocument.build(fake_issue, base_url: 'https://x')
    assert_equal true, doc['editable']['can_delete']
    assert_equal true, doc['editable']['can_add_notes']
  end

  def test_editable_action_permissions_reflect_the_user_role
    # A user Redmine forbids from deleting/adding-notes gets false, so the client
    # hides those actions (Redmine still enforces on write).
    issue = fake_issue
    issue.stubs(:deletable?).returns(false)
    issue.stubs(:notes_addable?).returns(false)
    doc = RedmineGttSync::IssueDocument.build(issue, base_url: 'https://x')
    assert_equal false, doc['editable']['can_delete']
    assert_equal false, doc['editable']['can_add_notes']
  end

  def test_journal_carries_notes_editable_flag
    issue = fake_issue
    issue.journals = [
      fake_journal(notes: 'Looks fixed', editable: true, id: 1),
      fake_journal(notes: 'Not yours', editable: false, id: 2)
    ]
    journals = RedmineGttSync::IssueDocument.build(issue, base_url: 'https://x')['journals']
    assert_equal([true, false], journals.map { |j| j['notes_editable'] })
    # A false flag must survive .compact (only nil is dropped), so the client can
    # positively know it may NOT edit rather than guessing from a missing key.
    assert journals[1].key?('notes_editable')
  end

  def test_note_less_journal_omits_notes_editable
    # A pure property-change entry (no note text) has nothing to edit, so
    # notes_editable is omitted rather than advertised ambiguously.
    issue = fake_issue
    issue.journals = [fake_journal(notes: nil, editable: true, id: 3)]
    journal = RedmineGttSync::IssueDocument.build(issue, base_url: 'https://x')['journals'][0]
    refute journal.key?('notes_editable')
    refute journal.key?('notes')
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

  def test_editable_references_offer_options_only_for_writable_fields
    issue = fake_issue
    issue.stubs(:safe_attribute_names).returns(%w[subject assigned_to_id priority_id])
    issue.stubs(:assignable_users).returns([OpenStruct.new(id: 8, name: 'Field Worker')])
    IssuePriority.stubs(:active).returns([OpenStruct.new(id: 2, name: 'Normal')])
    # The non-writable reference fields must not be queried at all.
    issue.expects(:assignable_versions).never
    issue.project.expects(:issue_categories).never

    refs = RedmineGttSync::IssueDocument.build(
      issue, base_url: 'https://x'
    )['editable']['references']
    assert_equal [{ 'id' => 8, 'name' => 'Field Worker' }], refs['assigned_to_id']
    assert_equal [{ 'id' => 2, 'name' => 'Normal' }], refs['priority_id']
    refute refs.key?('category_id')
    refute refs.key?('fixed_version_id')
  end

  def test_editable_references_cover_all_four_reference_fields
    issue = fake_issue
    issue.stubs(:safe_attribute_names).returns(
      %w[assigned_to_id priority_id category_id fixed_version_id]
    )
    issue.stubs(:assignable_users).returns([OpenStruct.new(id: 8, name: 'Worker')])
    issue.stubs(:assignable_versions).returns([OpenStruct.new(id: 4, name: 'v1')])
    issue.project.stubs(:issue_categories).returns([OpenStruct.new(id: 3, name: 'Signs')])
    IssuePriority.stubs(:active).returns([OpenStruct.new(id: 2, name: 'Normal')])

    refs = RedmineGttSync::IssueDocument.build(
      issue, base_url: 'https://x'
    )['editable']['references']
    assert_equal %w[assigned_to_id priority_id category_id fixed_version_id].sort,
                 refs.keys.sort
    assert_equal [{ 'id' => 3, 'name' => 'Signs' }], refs['category_id']
    assert_equal [{ 'id' => 4, 'name' => 'v1' }], refs['fixed_version_id']
  end

  def test_user_custom_field_value_carries_value_options
    field = OpenStruct.new(id: 7, name: 'Reviewer', field_format: 'user',
                           multiple: false, possible_values: nil)
    # possible_values_options yields [label, value] pairs for user/version fields,
    # resolved against the issue (so the options are the ones assignable here).
    field.stubs(:possible_values_options).returns([%w[Alice 3], %w[Bob 5]])
    value = OpenStruct.new(custom_field: field, custom_field_id: 7, value: '3')
    issue = fake_issue
    issue.visible_custom_field_values = [value]

    cf = RedmineGttSync::IssueDocument.build(issue, base_url: 'https://x')['custom_fields'][0]
    assert_equal 'user', cf['field_format']
    assert_equal(
      [{ 'value' => '3', 'label' => 'Alice' }, { 'value' => '5', 'label' => 'Bob' }],
      cf['value_options']
    )
  end

  def test_list_custom_field_value_has_empty_value_options
    field = OpenStruct.new(id: 5, name: 'Severity', field_format: 'list',
                           multiple: false, possible_values: %w[Low High])
    value = OpenStruct.new(custom_field: field, custom_field_id: 5, value: 'High')
    issue = fake_issue
    issue.visible_custom_field_values = [value]

    cf = RedmineGttSync::IssueDocument.build(issue, base_url: 'https://x')['custom_fields'][0]
    # list uses possible_values (strings); value_options stays empty.
    assert_equal [], cf['value_options']
    assert_equal %w[Low High], cf['possible_values']
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

  # -- change lines: reference-attribute labels -----------------------------

  def build_change(detail, base = 'https://x')
    # change is a public module function (module_function), so call it directly.
    RedmineGttSync::IssueDocument.change(base, detail)
  end

  def test_change_resolves_reference_attribute_to_display_name
    detail = OpenStruct.new(property: 'attr', prop_key: 'status_id',
                            old_value: '1', value: '2')
    klass = mock
    klass.stubs(:find_by).with(id: '1').returns(OpenStruct.new(name: 'New'))
    klass.stubs(:find_by).with(id: '2').returns(OpenStruct.new(name: 'In Progress'))
    Issue.stubs(:reflect_on_association).with(:status)
         .returns(OpenStruct.new(klass: klass))

    change = build_change(detail)
    # Raw ids stay authoritative; labels are added alongside.
    assert_equal '1', change['old_value']
    assert_equal '2', change['new_value']
    assert_equal 'New', change['old_label']
    assert_equal 'In Progress', change['new_label']
  end

  def test_change_reference_label_omitted_when_record_deleted
    detail = OpenStruct.new(property: 'attr', prop_key: 'fixed_version_id',
                            old_value: nil, value: '99')
    klass = mock
    klass.stubs(:find_by).with(id: '99').returns(nil) # version removed since
    Issue.stubs(:reflect_on_association).with(:fixed_version)
         .returns(OpenStruct.new(klass: klass))

    change = build_change(detail)
    assert_equal '99', change['new_value']
    refute change.key?('new_label'), 'no label for a deleted record'
    refute change.key?('old_label')
  end

  def test_change_literal_attribute_gets_no_label
    detail = OpenStruct.new(property: 'attr', prop_key: 'done_ratio',
                            old_value: '0', value: '30')
    change = build_change(detail)
    assert_equal({ 'property' => 'attr', 'name' => 'done_ratio',
                   'old_value' => '0', 'new_value' => '30' }, change)
  end

  def test_change_custom_field_and_attachment_get_no_reference_label
    cf = OpenStruct.new(property: 'cf', prop_key: '1', old_value: '2', value: '3')
    att = OpenStruct.new(property: 'attachment', prop_key: '4',
                         old_value: nil, value: 'logo.png')
    refute build_change(cf).key?('new_label')
    refute build_change(att).key?('new_label')
  end

  def test_description_change_links_to_diff_and_omits_text
    detail = OpenStruct.new(property: 'attr', prop_key: 'description',
                            old_value: 'a very long old body',
                            value: 'a very long new body',
                            journal_id: 22, id: 34)
    # A trailing slash on base must not double up in the URL.
    change = build_change(detail, 'https://x/')
    assert_equal 'https://x/journals/22/diff?detail_id=34', change['diff_url']
    # The heavy before/after text is dropped in favour of the diff link.
    refute change.key?('old_value')
    refute change.key?('new_value')
  end

  # -- journals: private-note flag ------------------------------------------

  def test_journal_carries_private_notes_flag
    journal = OpenStruct.new(id: 7, user: nil, created_on: nil,
                             notes: 'internal only', private_notes: true)
    journal.stubs(:visible?).returns(true)
    # journals now reads editable_by? for every visible note (notes_editable).
    journal.stubs(:editable_by?).returns(false)
    journal.stubs(:visible_details).returns([])
    issue = fake_issue
    issue.journals = [journal]

    journals = RedmineGttSync::IssueDocument.build(issue, base_url: 'https://x')[
      'journals'
    ]
    assert_equal true, journals[0]['private_notes']
    assert_equal 'internal only', journals[0]['notes']
  end
end
