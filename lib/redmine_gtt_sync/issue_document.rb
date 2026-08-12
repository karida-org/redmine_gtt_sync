# frozen_string_literal: true

require 'erb'

module RedmineGttSync
  # A single issue as a JSON-LD document: a portable, linked-data representation
  # anchored by the issue's canonical IRI (@id), carrying geometry as both
  # GeoJSON and EWKT. This is the identity foundation the client and the
  # portable-issue / connection-manager features resolve against: the IRI is the
  # issue's global name, independent of transport.
  #
  # It is also the CANONICAL issue data model consumed by two paths: QTask's
  # on-demand issue detail panel (online) and offline packaging for QField (the
  # same sections materialized into the container). Beyond geometry + core
  # fields it carries the issue's journals/notes, relations, changesets, and
  # attachments (split image vs other). Everything is permission-scoped: it never
  # exposes what the current user may not see.
  module IssueDocument
    # Inline JSON-LD context: schema.org for the issue vocabulary, GeoSPARQL for
    # the WKT literal, GeoJSON-LD for the geometry term. Inlined (not a hosted
    # URL) so the document is self-contained and needs no network to interpret.
    CONTEXT = {
      '@vocab' => 'https://schema.org/',
      'gtt' => 'https://gtt-project.org/ns/gtt#',
      'geo' => 'http://www.opengis.net/ont/geosparql#',
      'geojson' => 'https://purl.org/geojson/vocab#',
      'geometry' => 'geojson:geometry',
      'asWKT' => { '@id' => 'geo:asWKT', '@type' => 'geo:wktLiteral' },
      'journals' => 'gtt:journals',
      'relations' => 'gtt:relations',
      'changesets' => 'gtt:changesets',
      'attachments' => 'gtt:attachments',
      'custom_fields' => 'gtt:customFields',
      'editable' => 'gtt:editable'
    }.freeze

    module_function

    # Build the JSON-LD hash for +issue+. +base_url+ is the instance origin
    # (e.g. "https://example.com"); IRIs are built from it so they match the
    # instance's canonical addresses regardless of the request host. +user+ is
    # the acting user every permission-scoped section is resolved for - passed
    # in explicitly (the controller hands over User.current) so this module
    # stays a pure shaper with no hidden global input.
    def build(issue, base_url:, user:)
      base = base_url.to_s.chomp('/')
      geom = issue.geom
      {
        '@context' => CONTEXT,
        '@id' => "#{base}/issues/#{issue.id}",
        '@type' => 'gtt:Issue',
        'identifier' => issue.id,
        'subject' => issue.subject,
        'description' => issue.description.presence,
        'status' => reference(base, 'issue_statuses', issue.status),
        'tracker' => reference(base, 'trackers', issue.tracker),
        'project' => project_reference(base, issue.project),
        # Core fields, taken from Issue's real columns/associations (confirmed by
        # ActiveRecord reflection, not guessed from REST): references compact out
        # when unset; is_private/done_ratio stay (false/0 are meaningful).
        'priority' => reference(base, 'enumerations', issue.priority),
        'author' => reference(base, 'users', issue.author),
        'assigned_to' => reference(base, 'users', issue.assigned_to),
        'category' => reference(base, 'issue_categories', issue.category),
        'fixed_version' => reference(base, 'versions', issue.fixed_version),
        'parent' => parent_reference(base, issue),
        'start_date' => issue.start_date&.iso8601,
        'due_date' => issue.due_date&.iso8601,
        'done_ratio' => issue.done_ratio,
        'estimated_hours' => issue.estimated_hours,
        'is_private' => issue.is_private,
        'geometry' => Geometry.to_geojson(geom),
        'asWKT' => Geometry.to_ewkt(geom),
        'lock_version' => issue.lock_version,
        'created_on' => issue.created_on&.iso8601,
        'updated_on' => issue.updated_on&.iso8601,
        'closed_on' => issue.closed_on&.iso8601,
        # Rich sections (always present, possibly empty) - the data model both the
        # online detail panel and offline packaging consume.
        'journals' => journals(base, issue, user),
        'relations' => relations(base, issue, user),
        'changesets' => changesets(issue, user),
        'attachments' => attachments(base, issue, user),
        'custom_fields' => custom_fields(issue, user),
        'editable' => editable(issue, user)
      }.compact
    end

    # The RBAC editing contract for THIS issue + user: exactly what Redmine will
    # accept, so a client never loses edits to a silent safe_attributes drop and
    # only offers valid status transitions. We delegate the rules to Redmine
    # (safe_attribute_names encodes role + per-tracker workflow + per-status
    # field permissions; new_statuses_allowed_to encodes the workflow), rather
    # than reimplementing the permission model.
    def editable(issue, user)
      writable = issue.safe_attribute_names(user)
      {
        'fields' => writable,
        # Issue-level action permissions, delegated to Redmine so the client can
        # offer delete/add-note only when the user's role allows it (Redmine
        # still enforces on write). deletable? -> :delete_issues,
        # notes_addable? -> :add_issue_notes, both role + per-tracker scoped.
        'can_delete' => issue.deletable?(user),
        'can_add_notes' => issue.notes_addable?(user),
        # attachments_addable? -> add_issue_notes OR edit_issues (Redmine's own
        # attach rule), so clients can gate an upload button without proxying.
        'can_add_attachments' => issue.attachments_addable?(user),
        # time_loggable? -> :log_time plus the closed-issues setting, so a
        # client can hide time logging instead of collecting a 403 (#89).
        'can_log_time' => issue.time_loggable?(user),
        'status_transitions' => issue.new_statuses_allowed_to(user).map do |status|
          { 'id' => status.id, 'name' => status.name }
        end,
        'references' => ReferenceOptions.for_issue(issue, writable)
      }
    end

    # Custom field values for this issue, with editing metadata (possible_values
    # + writable) so the detail panel can build a permission-aware edit form. The
    # bundle uses the lean CustomFields.values instead (see CustomFields).
    def custom_fields(issue, user)
      CustomFields.detailed_values(issue, user)
    end

    def reference(base, path, record)
      return nil if record.nil?

      { '@id' => "#{base}/#{path}/#{record.id}", 'id' => record.id, 'name' => record.name }
    end

    def parent_reference(base, issue)
      return nil unless issue.parent_id

      { '@id' => "#{base}/issues/#{issue.parent_id}", 'id' => issue.parent_id }
    end

    def project_reference(base, project)
      return nil if project.nil?

      {
        '@id' => "#{base}/projects/#{project.identifier}",
        'id' => project.id,
        'identifier' => project.identifier,
        'name' => project.name
      }
    end

    # Notes + change history, only the entries visible to the user. NOTE:
    # Journal#visible? only re-checks the ISSUE's visibility - it does NOT
    # filter private notes (core filters those separately, see
    # Issue#visible_journals_with_index). Mirror that rule here: a private note
    # is included only for users with view_private_notes or its own author.
    # Role-restricted detail changes are filtered per journal (visible_details).
    def journals(base, issue, user)
      entries = issue.journals.select { |journal| journal.visible?(user) }
      unless user.allowed_to?(:view_private_notes, issue.project)
        entries = entries.reject do |journal|
          journal.private_notes? && journal.user != user
        end
      end
      # One label cache per document build: reference changes repeat the same
      # few records across a history (a handful of statuses, assignees, ...), so
      # memoizing by [association, id] collapses the per-detail lookups instead
      # of hitting the DB twice for every detail.
      label_cache = {}
      entries.map do |journal|
        {
          'id' => journal.id,
          'user' => reference(base, 'users', journal.user),
          'created_on' => journal.created_on&.iso8601,
          'notes' => journal.notes.presence,
          # A private note is only ever in this payload if the user may see it
          # (visible? above), but the client still needs the flag to mark it.
          'private_notes' => journal.private_notes,
          # Whether THIS user may edit (or clear = delete) this note's text.
          # Only meaningful when there IS note text (a pure property-change entry
          # has nothing to edit), so it's omitted for note-less journals to keep
          # the per-note semantics unambiguous. editable_by? covers
          # edit_issue_notes (any) and edit_own_issue_notes (own); the client
          # shows Edit/Delete only when true, Redmine enforces the same on the
          # stock PUT /journals/:id.json write.
          'notes_editable' => (journal.editable_by?(user) if journal.notes.present?),
          'details' => journal.visible_details(user).map do |detail|
            change(base, detail, user, label_cache)
          end
        }.compact
      end
    end

    def change(base, detail, user, label_cache = {})
      # A description edit (and other long-text) carries a large before/after
      # that is noise inline; link to Redmine's own diff page instead of shipping
      # the full text. Redmine renders exactly this diff at journals/:id/diff.
      if diffable?(detail) && detail.journal_id && detail.id
        return {
          'property' => detail.property,
          'name' => detail.prop_key,
          'diff_url' =>
            "#{base.to_s.chomp('/')}/journals/#{detail.journal_id}" \
            "/diff?detail_id=#{detail.id}"
        }
      end

      change = {
        'property' => detail.property,
        'name' => detail.prop_key,
        'old_value' => detail.old_value,
        'new_value' => detail.value
      }
      # For reference attributes (status_id, assigned_to_id, ...) the raw values
      # are record ids, which read as noise in a client's history. Resolve them
      # to display names here, where we can honour deletions and don't force the
      # client to fetch and join the status/user/version/... dictionaries. Only
      # added when resolvable, so old_value/new_value stay authoritative.
      old_label = reference_label(detail, detail.old_value, user, label_cache)
      new_label = reference_label(detail, detail.value, user, label_cache)
      change['old_label'] = old_label if old_label
      change['new_label'] = new_label if new_label
      change
    end

    # A change whose value is long text best shown as a diff rather than inline:
    # the issue description today. (Long-text custom fields could join later; the
    # client falls back to the inline value when there is no diff_url.)
    def diffable?(detail)
      detail.property == 'attr' && detail.prop_key.to_s == 'description'
    end

    # The display name for a reference-attribute change value, or nil when it
    # isn't a resolvable reference (a literal like done_ratio, a custom field, an
    # attachment) or the referenced record is gone. Mirrors how Redmine's own
    # history resolves an "<assoc>_id" attribute against its association, so the
    # labels match the web UI (and honour records deleted since the change).
    # ``label_cache`` memoizes [association, id] lookups across a document build.
    def reference_label(detail, value, user, label_cache = {})
      return nil unless detail.property == 'attr'

      key = detail.prop_key.to_s
      return nil unless value.present? && key.end_with?('_id')

      assoc_name = key.sub(/_id\z/, '').to_sym
      cache_key = [assoc_name, value.to_s]
      return label_cache[cache_key] if label_cache.key?(cache_key)

      label_cache[cache_key] = resolve_reference_name(assoc_name, value, user)
    end

    # Mirrors IssuesHelper#find_name_by_reflection: only ``name`` is ever
    # resolved, and a Project must be visible to this user. Core is deliberate
    # about both. Anything else (a parent issue, say) keeps its bare id, the
    # same way core renders "##{detail.value}" rather than a subject the
    # reader may not be allowed to see.
    def resolve_reference_name(assoc_name, value, user)
      association = Issue.reflect_on_association(assoc_name)
      return nil unless association

      record = association.klass.find_by(id: value)
      return nil unless record
      return nil unless record.respond_to?(:name)
      return nil if record.is_a?(Project) && !record.visible?(user)

      record.name
    rescue NameError => e
      # Degrade to no label only for the expected lookup fault: a reflection
      # whose class can't be resolved (e.g. a polymorphic association raises
      # from #klass; NameError also covers NoMethodError). A missing record is
      # not an exception path - find_by returns nil and the guard above handles
      # it. Anything else raises: a broad rescue here would mask real bugs by
      # silently degrading every history label instead of failing a test.
      Rails.logger&.warn(
        "[gtt_sync] reference label lookup failed for #{assoc_name}=#{value}: " \
        "#{e.class}: #{e.message}"
      )
      nil
    end

    # Issue relations, only to issues the user can see.
    def relations(base, issue, user)
      issue.relations.filter_map do |relation|
        other = relation.other_issue(issue)
        next if other.nil? || !other.visible?(user)

        {
          'type' => relation.relation_type,
          'delay' => relation.delay,
          'issue' => {
            '@id' => "#{base}/issues/#{other.id}",
            'id' => other.id,
            'subject' => other.subject
          }
        }.compact
      end
    end

    # Linked repository commits, only when the user may view changesets.
    def changesets(issue, user)
      return [] unless user.allowed_to?(:view_changesets, issue.project)

      issue.changesets.map do |changeset|
        {
          'revision' => changeset.revision,
          'committed_on' => changeset.committed_on&.iso8601,
          'committer' => changeset.committer,
          'comments' => changeset.comments.presence
        }.compact
      end
    end

    # Attachments, split image vs other so a client can render photos with
    # thumbnails and list other files as links. Filtered through Redmine's own
    # Attachment#visible? so we never expose files the user may not see (delegate
    # the rule to Redmine rather than reimplement it).
    def attachments(base, issue, user)
      visible = issue.attachments.select { |attachment| attachment.visible?(user) }
      visible.map do |attachment|
        image = attachment.image?
        name = ERB::Util.url_encode(attachment.filename)
        {
          'id' => attachment.id,
          'filename' => attachment.filename,
          'filesize' => attachment.filesize,
          'content_type' => attachment.content_type.presence,
          'description' => attachment.description.presence,
          'author' => reference(base, 'users', attachment.author),
          'created_on' => attachment.created_on&.iso8601,
          'is_image' => image,
          'url' => "#{base}/attachments/download/#{attachment.id}/#{name}",
          'thumbnail_url' => (image ? "#{base}/attachments/thumbnail/#{attachment.id}" : nil),
          # Per-attachment action permissions for this user, delegated to
          # Redmine (editable?/deletable? ride on the issue's edit permission),
          # so the client offers Edit/Delete only when allowed. Coerced to a
          # strict bool so a false is advertised explicitly, not dropped.
          'editable' => !!attachment.editable?(user),
          'deletable' => !!attachment.deletable?(user)
        }.compact
      end
    end
  end
end
