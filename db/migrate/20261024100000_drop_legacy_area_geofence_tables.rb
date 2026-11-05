# frozen_string_literal: true

# Databases that ran the earlier area-based geofencing branch keep empty
# geofence_events, webhooks and webhook_deliveries tables whose shape the
# Places-based 1.18 migrations would silently skip over (if_not_exists).
class DropLegacyAreaGeofenceTables < ActiveRecord::Migration[8.1]
  TABLES = %i[webhook_deliveries webhooks geofence_events].freeze

  def up
    return unless table_exists?(:geofence_events) && column_exists?(:geofence_events, :area_id)

    tables = TABLES.select { |table| table_exists?(table) }
    populated = tables.reject { |table| select_value("SELECT COUNT(*) FROM #{table}").to_i.zero? }
    raise "Refusing to drop legacy tables that hold rows: #{populated.join(', ')}" if populated.any?

    tables.each { |table| drop_table table }
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
