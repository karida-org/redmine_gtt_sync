module RedmineGttSync
  # Shared shaping of an issue's custom-field VALUES, used by both the single
  # issue document and the bundle (so the detail panel and the whole loaded set
  # carry the same shape).
  #
  # Aligned with Redmine's REST `custom_fields: [{id, name, value}]` but enriched
  # with `field_format` + `multiple` so a client can render/edit without a second
  # `/custom_fields.json` call. Only the fields applicable to this issue's
  # project/tracker and visible to the user are returned (delegated to
  # `visible_custom_field_values`); `value` is Redmine's stored value: a string,
  # an array for multi-value fields, or null when unset.
  module CustomFields
    module_function

    # Reference-like formats store an id/key but display a name, so a client
    # needs the selectable options to build a picker. A plain `list` uses its
    # `possible_values` strings (value == label) and `bool` is handled
    # client-side, so both are deliberately left out here.
    REFERENCE_FORMATS = %w[user version enumeration].freeze

    # Lean shape for the bundle (whole loaded set): identity + type + value.
    def values(issue)
      issue.visible_custom_field_values.map { |value| base(value) }
    end

    # Selectable {value,label} options for a reference-like custom field,
    # resolved in `context` (the issue, or a new issue for a project) so
    # user/version options are scoped correctly. Empty for other formats, where
    # a client uses `possible_values` instead. Redmine's possible_values_options
    # yields [label, value] pairs for id-based formats; normalize to explicit
    # {value,label} so the client never has to guess which half is which.
    def value_options(field, context)
      return [] unless REFERENCE_FORMATS.include?(field.field_format)

      field.possible_values_options(context).map do |option|
        label, value = option.is_a?(Array) ? [option.first, option.last] : [option, option]
        { 'value' => value.to_s, 'label' => label.to_s }
      end
    end

    # Editing shape for the single issue document: adds the field's
    # `possible_values` (for list-type widgets) and `writable` (whether THIS user
    # may edit THIS field on THIS issue, per Redmine's editable_custom_field_values
    # - role + tracker + workflow). Lets a client build a permission-aware edit
    # form and never offer an edit Redmine would silently drop.
    def detailed_values(issue, user)
      # A plain array (not a Set) so we don't depend on `set` being required;
      # the editable-field list per issue is small, so include? is fine.
      editable_ids = issue.editable_custom_field_values(user).map(&:custom_field_id)
      issue.visible_custom_field_values.map do |value|
        field = value.custom_field
        base(value).merge(
          'possible_values' => field.possible_values || [],
          # Resolved against this issue, so user/version options are the ones
          # actually assignable here.
          'value_options' => value_options(field, issue),
          'writable' => editable_ids.include?(field.id)
        )
      end
    end

    def base(value)
      field = value.custom_field
      {
        'id' => field.id,
        'name' => field.name,
        'field_format' => field.field_format,
        'multiple' => field.multiple,
        'value' => value.value
      }
    end
  end
end
