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
      writable = issue.safe_attribute_names(user)
      {
        'fields' => writable,
        'status_transitions' => issue.new_statuses_allowed_to(user).map do |status|
          { 'id' => status.id, 'name' => status.name }
        end,
        'references' => reference_options(issue, writable)
      }
    end

    # Allowed {id, name} options for the writable reference fields, so a client
    # can offer real dropdowns for assignee / priority / category / version
    # instead of a raw id. Only fields the user may write are included (gated by
    # safe_attribute_names), and the option sets are delegated to Redmine so
    # project scoping and visibility stay correct.
    def reference_options(issue, writable)
      # Lazy sources so a non-writable field's options are never queried.
      sources = {
        'assigned_to_id' => -> { issue.assignable_users },
        'priority_id' => -> { IssuePriority.active },
        'category_id' => -> { issue.project.issue_categories },
        'fixed_version_id' => -> { issue.assignable_versions }
      }
      sources.each_with_object({}) do |(field, source), options|
        options[field] = named(source.call) if writable.include?(field)
      end
    end

    def named(records)
      records.map { |record| { 'id' => record.id, 'name' => record.name } }
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
      # One label cache per document build: reference changes repeat the same
      # few records across a history (a handful of statuses, assignees, ...), so
      # memoizing by [association, id] collapses the per-detail lookups instead
      # of hitting the DB twice for every detail.
      label_cache = {}
      issue.journals.select { |journal| journal.visible?(user) }.map do |journal|
        {
          'id' => journal.id,
          'user' => reference(base, 'users', journal.user),
          'created_on' => journal.created_on&.iso8601,
          'notes' => journal.notes.presence,
          # A private note is only ever in this payload if the user may see it
          # (visible? above), but the client still needs the flag to mark it.
          'private_notes' => journal.private_notes,
          'details' => journal.visible_details(user).map do |detail|
            change(base, detail, label_cache)
          end
        }.compact
      end
    end

    def change(base, detail, label_cache = {})
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
      old_label = reference_label(detail, detail.old_value, label_cache)
      new_label = reference_label(detail, detail.value, label_cache)
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
    def reference_label(detail, value, label_cache = {})
      return nil unless detail.property == 'attr'

      key = detail.prop_key.to_s
      return nil unless value.present? && key.end_with?('_id')

      assoc_name = key.sub(/_id\z/, '').to_sym
      cache_key = [assoc_name, value.to_s]
      return label_cache[cache_key] if label_cache.key?(cache_key)

      label_cache[cache_key] = resolve_reference_name(assoc_name, value)
    end

    def resolve_reference_name(assoc_name, value)
      association = Issue.reflect_on_association(assoc_name)
      return nil unless association

      record = association.klass.find_by(id: value)
      return nil unless record

      if record.respond_to?(:name)
        record.name
      elsif record.respond_to?(:subject)
        record.subject
      else
        record.to_s
      end
    rescue StandardError => e
      # Never let a label lookup break the document, but leave a trace so a real
      # reflection/query fault is diagnosable rather than silently swallowed.
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
          'thumbnail_url' => (image ? "#{base}/attachments/thumbnail/#{attachment.id}" : nil)
        }.compact
      end
    end
  end
end
