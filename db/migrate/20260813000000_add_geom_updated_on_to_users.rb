# frozen_string_literal: true

# Freshness for the user location redmine_gtt stores in users.geom.
#
# users.updated_on moves on any profile change, so it cannot answer "when was
# this person last here?" - which is the whole point of reading a colleague's
# location. This column is set only when the location itself changes.
class AddGeomUpdatedOnToUsers < ActiveRecord::Migration[7.2]
  def up
    return if column_exists?(:users, :geom_updated_on)

    add_column :users, :geom_updated_on, :datetime, null: true
  end

  def down
    return unless column_exists?(:users, :geom_updated_on)

    remove_column :users, :geom_updated_on
  end
end
