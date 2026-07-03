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

    def values(issue)
      issue.visible_custom_field_values.map do |value|
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
end
