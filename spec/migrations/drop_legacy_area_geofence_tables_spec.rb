# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20261024100000_drop_legacy_area_geofence_tables.rb')

RSpec.describe DropLegacyAreaGeofenceTables do
  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }

  def recreate_tables(reference_column)
    %i[webhook_deliveries webhooks geofence_events].each { |table| connection.drop_table(table, if_exists: true) }
    connection.create_table(:geofence_events) { |t| t.bigint reference_column, null: false }
    connection.create_table(:webhooks) { |t| t.string :name }
    connection.create_table(:webhook_deliveries) { |t| t.bigint :geofence_event_id }
  end

  it 'drops the empty tables left by the area-based geofencing branch' do
    recreate_tables(:area_id)

    migration.up

    expect(%i[geofence_events webhooks webhook_deliveries].map { |t| connection.table_exists?(t) }).to all(be(false))
  end

  it 'leaves Places-based tables alone' do
    recreate_tables(:place_id)

    migration.up

    expect(connection.table_exists?(:geofence_events)).to be(true)
  end

  it 'refuses to drop legacy tables that hold rows' do
    recreate_tables(:area_id)
    connection.execute('INSERT INTO geofence_events (area_id) VALUES (1)')

    expect { migration.up }.to raise_error(/Refusing to drop legacy tables that hold rows: geofence_events/)
  end
end
