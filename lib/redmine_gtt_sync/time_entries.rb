# frozen_string_literal: true

module RedmineGttSync
  # Serialization for the time-entry contract (issue #89): the shape one entry
  # takes on the wire, and the index payload for the user's own entries.
  #
  # Same discipline as the rest of the contract: everything runs as the
  # authenticated user, and permissions stay delegated to Redmine
  # (TimeEntry.visible for reads, safe_attributes + :log_time for writes).
  module TimeEntries
    module_function

    # One time entry on the wire. Times are ISO 8601; hours is a plain float.
    def entry_hash(entry, user = User.current)
      hash = {
        'id' => entry.id,
        'project' => { 'id' => entry.project_id, 'name' => entry.project.name },
        'activity' => activity_hash(entry.activity),
        'hours' => entry.hours.to_f,
        'spent_on' => entry.spent_on&.iso8601,
        'comments' => entry.comments.to_s,
        'created_on' => entry.created_on&.iso8601,
        'updated_on' => entry.updated_on&.iso8601
      }
      # The subject only rides along when this user may see the issue itself.
      # TimeEntry.visible scopes on :view_time_entries, not issue visibility,
      # so an issue that became private after the time was logged would
      # otherwise leak its subject through the entry. Redmine's own timelog
      # API emits the id alone for the same reason.
      if entry.issue
        hash['issue'] = { 'id' => entry.issue_id }
        hash['issue']['subject'] = entry.issue.subject if entry.issue.visible?(user)
      end
      custom = custom_field_values(entry, user)
      hash['custom_fields'] = custom if custom.any?
      hash
    end

    # Index payload: the capped entry list plus totals computed over the WHOLE
    # filtered scope, so the summary stays correct even when the list is
    # truncated at the cap.
    def index(scope, limit:, user: User.current)
      entries = scope.includes(:project, :issue, :activity,
                               custom_values: :custom_field)
                     .order(spent_on: :desc, id: :desc)
                     .limit(limit)
                     .to_a
      {
        'time_entries' => entries.map { |entry| entry_hash(entry, user) },
        'total_count' => scope.count,
        'total_hours' => scope.sum(:hours).to_f,
        'limit' => limit
      }
    end

    # The project-schema section: whether this user may log time here, the
    # activities available in this project (system list with any per-project
    # overrides, via project.activities), the time-entry custom fields, and
    # the attribute names a create may carry (Redmine's own safe set).
    def schema_section(project, user)
      entry = TimeEntry.new(project: project, user: user, author: user)
      {
        'can_log_time' => user.allowed_to?(:log_time, project),
        'activities' => project.activities.map { |a| activity_hash(a) },
        'custom_fields' => TimeEntryCustomField.sorted
                                               .select { |cf| cf.visible_by?(project, user) }
                                               .map { |cf| custom_field_hash(cf) },
        'writable' => entry.safe_attribute_names(user)
      }
    end

    # Like ProjectSchema.custom_field_hash, minus the issue-only tracker
    # scoping (time-entry custom fields apply per project, not per tracker).
    def custom_field_hash(custom_field)
      {
        'id' => custom_field.id,
        'name' => custom_field.name,
        'field_format' => custom_field.field_format,
        'required' => custom_field.is_required,
        'multiple' => custom_field.multiple,
        'possible_values' => custom_field.possible_values
      }
    end

    def activity_hash(activity)
      return nil unless activity

      {
        'id' => activity.id,
        'name' => activity.name,
        'is_default' => activity.is_default == true
      }
    end

    def custom_field_values(entry, user)
      entry.visible_custom_field_values(user).filter_map do |value|
        next if value.value.blank?

        {
          'id' => value.custom_field_id,
          'name' => value.custom_field.name,
          'value' => value.value
        }
      end
    end
  end
end
