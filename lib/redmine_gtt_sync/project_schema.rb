module RedmineGttSync
  # Per-project editing schema for a client to build a correct, permission-aware
  # form: the applicable trackers, statuses, custom-field definitions, and the
  # field names the current user may actually write. This is what lets a client
  # avoid silent safe_attributes drops and the custom-fields hard part.
  #
  # Permission-safe: custom fields are filtered by the user's visibility, and the
  # writable set comes from Redmine's own safe_attribute_names, so it reflects
  # exactly what this user could write through the normal API.
  module ProjectSchema
    module_function

    def build(project, user)
      {
        'project' => {
          'id' => project.id,
          'identifier' => project.identifier,
          'name' => project.name
        },
        'trackers' => project.trackers.sorted.map { |t| { 'id' => t.id, 'name' => t.name } },
        'statuses' => IssueStatus.sorted.map do |s|
          { 'id' => s.id, 'name' => s.name, 'is_closed' => s.is_closed }
        end,
        'custom_fields' => custom_fields(project, user),
        'writable' => writable_fields(project, user)
      }
    end

    def custom_fields(project, user)
      project.all_issue_custom_fields
             .select { |cf| cf.visible_by?(project, user) }
             .map { |cf| custom_field_hash(cf) }
    end

    def custom_field_hash(custom_field)
      {
        'id' => custom_field.id,
        'name' => custom_field.name,
        'field_format' => custom_field.field_format,
        'required' => custom_field.is_required,
        'multiple' => custom_field.multiple,
        'possible_values' => custom_field.possible_values,
        'tracker_ids' => custom_field.trackers.map(&:id).sort
      }
    end

    # Core + custom attribute names a NEW issue exposes to this user; Redmine
    # drops anything else via safe_attributes, so a client won't send fields that
    # would be silently ignored (includes GTT's "geojson"). Per-status field
    # permissions are per-issue and left to a later per-issue schema.
    def writable_fields(project, user)
      tracker = project.trackers.sorted.first
      return [] unless tracker

      Issue.new(project: project, tracker: tracker, author: user).safe_attribute_names(user)
    end
  end
end
