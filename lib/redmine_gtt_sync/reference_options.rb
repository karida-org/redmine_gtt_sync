module RedmineGttSync
  # Allowed {id, name} options for the writable reference fields (assignee,
  # priority, category, target version), so a client can offer real dropdowns
  # instead of a raw id. Shared by the per-issue document (issue_document.rb,
  # which edits an existing issue) and the per-project new-issue schema
  # (project_schema.rb, which builds a create form): both gate on the writable
  # set and delegate the option sets to Redmine so project scoping and
  # visibility stay correct.
  module ReferenceOptions
    module_function

    # +issue+ is a real or stand-in Issue in the target project's context (it
    # must respond to #assignable_users, #project, #assignable_versions).
    # +writable+ is the user's safe_attribute_names set; a field's options are
    # queried only when that field is writable, so a non-writable field's option
    # source is never touched.
    def for_issue(issue, writable)
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
  end
end
