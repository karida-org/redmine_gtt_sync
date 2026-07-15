# frozen_string_literal: true

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
        'custom_fields' => custom_fields(project, user)
      }.merge(writable_and_references(project, user))
    end

    def custom_fields(project, user)
      # A stand-in issue for this project so user/version option lists resolve to
      # this project's assignable users/versions (they need an object that
      # responds to #project). Carry the acting user so option resolution stays
      # permission-consistent with writable_fields.
      context = Issue.new(project: project, author: user)
      project.all_issue_custom_fields
             .select { |cf| cf.visible_by?(project, user) }
             .map { |cf| custom_field_hash(cf, context) }
    end

    # ``context`` is optional (defaults to no option resolution) so the public
    # module_function API stays callable with just a custom field.
    def custom_field_hash(custom_field, context = nil)
      {
        'id' => custom_field.id,
        'name' => custom_field.name,
        'field_format' => custom_field.field_format,
        'required' => custom_field.is_required,
        'multiple' => custom_field.multiple,
        'possible_values' => custom_field.possible_values,
        'value_options' => CustomFields.value_options(custom_field, context),
        'tracker_ids' => custom_field.trackers.map(&:id).sort
      }
    end

    # Core + custom attribute names a NEW issue exposes to this user, plus the
    # {id, name} option lists for the writable reference fields
    # (assignee/priority/category/version). Both come from ONE stand-in Issue in
    # this project's context: Redmine's own safe_attribute_names gives the
    # writable set (so a client won't send fields safe_attributes would silently
    # drop, including GTT's "geojson"), and the same issue resolves the reference
    # option sets (assignable users/versions, project categories) with correct
    # scoping. Empty when the project has no tracker (nothing can be created).
    #
    # The writable set + references use the project's FIRST tracker; per-tracker
    # and per-status field permissions are per-issue and left to a later per-issue
    # schema.
    def writable_and_references(project, user)
      tracker = project.trackers.sorted.first
      return { 'writable' => [], 'references' => {} } unless tracker

      issue = Issue.new(project: project, tracker: tracker, author: user)
      writable = issue.safe_attribute_names(user)
      {
        'writable' => writable,
        'references' => ReferenceOptions.for_issue(issue, writable)
      }
    end
  end
end
