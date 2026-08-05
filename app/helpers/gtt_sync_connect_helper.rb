# frozen_string_literal: true

# View helpers for the Connect QGIS page.
module GttSyncConnectHelper
  # A table cell holding a connection value with an inline "Copy" button. The
  # button copies the sibling `.gtt-copy-value` text (single source of truth;
  # see assets/javascripts/gtt_sync_connect.js). +field+ names the value for
  # assistive tech (each button gets a distinct aria-label), and aria-live
  # announces the "Copied" state change.
  def gtt_sync_copy_cell(value, field)
    content_tag(:td) do
      concat content_tag(:code, value, class: 'gtt-copy-value')
      concat ' '
      concat copy_button(field)
    end
  end

  private

  def copy_button(field)
    content_tag(:button, l(:button_gtt_sync_copy),
                type: 'button',
                class: 'gtt-copy',
                'aria-label' => "#{l(:button_gtt_sync_copy)} #{field}",
                'aria-live' => 'polite',
                'data-label-copy' => l(:button_gtt_sync_copy),
                'data-label-copied' => l(:label_gtt_sync_copied))
  end
end
