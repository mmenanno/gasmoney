# frozen_string_literal: true

require "active_record"
require "fileutils"
require "logger"

require_relative "models/vehicle"
require_relative "models/fillup"
require_relative "models/trip_search"
require_relative "models/saved_trip"

module GasMoney
  module DB
    DEFAULT_PATH = ENV.fetch(
      "GASMONEY_DB_PATH",
      File.expand_path("../db/gasmoney.sqlite3", __dir__),
    )

    def self.connect(path = DEFAULT_PATH)
      FileUtils.mkdir_p(File.dirname(path)) unless path == ":memory:"
      first_boot = path == ":memory:" || !File.exist?(path)

      ActiveRecord::Base.establish_connection(
        adapter: "sqlite3",
        database: path,
        pool: 5,
        timeout: 5_000,
      )
      ActiveRecord::Base.logger = Logger.new(IO::NULL)
      ActiveRecord::Migration.verbose = false

      ensure_schema!
      migrate!

      [path, first_boot]
    end

    def self.ensure_schema!
      ActiveRecord::Schema.define do
        create_table(:vehicles, if_not_exists: true) do |t|
          t.string(:display_name, null: false)
          t.boolean(:pinned, null: false, default: false)
        end

        create_table(:fillups, if_not_exists: true) do |t|
          t.references(:vehicle, null: false)
          t.string(:filled_at, null: false)
          t.float(:total_cost,       null: false)
          t.float(:quantity_liters,  null: false)
          t.float(:unit_price_cents, null: false)
          t.integer(:odometer)
          # `l_per_100km IS NULL` doubles as the "partial fill" signal.
          t.float(:l_per_100km)
          t.index(
            [:vehicle_id, :filled_at, :odometer, :quantity_liters],
            unique: true,
            name: "idx_fillups_dedup",
          )
          t.index([:vehicle_id, :filled_at], name: "idx_fillups_vehicle_filled_at")
        end

        create_table(:trip_searches, if_not_exists: true) do |t|
          t.references(:vehicle, null: false)
          t.string(:trip_date, null: false)
          t.float(:kilometers,       null: false)
          t.float(:estimated_cost,   null: false)
          t.float(:liters_used,      null: false)
          t.float(:unit_price_cents, null: false)
          t.float(:l_per_100km,      null: false)
          t.string(:calc_method, null: false)
          t.string(
            :created_at,
            null: false,
            default: -> { "(strftime('%Y-%m-%dT%H:%M:%fZ','now'))" },
          )
        end

        create_table(:saved_trips, if_not_exists: true) do |t|
          t.string(:name, null: false)
          t.float(:base_kilometers, null: false)
          t.integer(:round_trip, null: false, default: 0)
          t.string(
            :created_at,
            null: false,
            default: -> { "(strftime('%Y-%m-%dT%H:%M:%fZ','now'))" },
          )
        end
      end
    end

    # Idempotent in-place migrations for upgrades from earlier schema
    # versions. Each step guards on its own column / index existence so
    # re-running on every boot is a no-op once converged.
    def self.migrate!
      conn = ActiveRecord::Base.connection

      unless conn.column_exists?(:vehicles, :pinned)
        conn.add_column(:vehicles, :pinned, :boolean, null: false, default: false)
        # Existing rows pre-date the dashboard-pinning concept; preserve their
        # at-a-glance presence by pinning them. New vehicles default to false.
        conn.execute("UPDATE vehicles SET pinned = 1")
      end

      [:slug, :csv_vehicle].each do |col|
        conn.remove_column(:vehicles, col) if conn.column_exists?(:vehicles, col)
      end

      # Drop fillup columns the app never reads after writing. Surfaced
      # by an audit pass: `partial_fill` is redundant with `l_per_100km
      # IS NULL` (which is what every consumer was already checking),
      # and `fuel_type`/`location`/`city`/`notes` were imported from the
      # CSV but never displayed back. Existing data in those columns is
      # discarded — nothing in the app reads it.
      [:partial_fill, :fuel_type, :location, :city, :notes].each do |col|
        conn.remove_column(:fillups, col) if conn.column_exists?(:fillups, col)
      end

      Vehicle.reset_column_information
      Fillup.reset_column_information
    end
  end
end
