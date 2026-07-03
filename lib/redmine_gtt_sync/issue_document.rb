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
      'gtt' => 'https://karida.info/ns/gtt#',
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
    # instance's canonical addresses regardless of the request host.
    def build(issue, base_url:)
      base = base_url.to_s.chomp('/')
      user = User.current
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
      {
        'fields' => issue.safe_attribute_names(user),
        'status_transitions' => issue.new_statuses_allowed_to(user).map do |status|
          { 'id' => status.id, 'name' => status.name }
        end
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

    # Notes + change history, only the entries visible to the user (private notes
    # and role-restricted detail changes are filtered by Redmine).
    def journals(base, issue, user)
      issue.journals.select { |journal| journal.visible?(user) }.map do |journal|
        {
          'id' => journal.id,
          'user' => reference(base, 'users', journal.user),
          'created_on' => journal.created_on&.iso8601,
          'notes' => journal.notes.presence,
          'details' => journal.visible_details(user).map { |detail| change(detail) }
        }.compact
      end
    end

    def change(detail)
      {
        'property' => detail.property,
        'name' => detail.prop_key,
        'old_value' => detail.old_value,
        'new_value' => detail.value
      }
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
          'thumbnail_url' => (image ? "#{base}/attachments/thumbnail/#{attachment.id}" : nil)
        }.compact
      end
    end
  end
end
