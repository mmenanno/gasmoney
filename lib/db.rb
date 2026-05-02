# frozen_string_literal: true

require "active_record"
require "fileutils"
require "logger"

require_relative "encryption"
require_relative "models/vehicle"
require_relative "models/fillup"
require_relative "models/trip_search"
require_relative "models/saved_trip"
require_relative "models/gasbuddy_setting"
require_relative "models/sync_run"
require_relative "models/sync_log_entry"

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

      Encryption.configure!

      ensure_schema!
      migrate!

      [path, first_boot]
    end

    def self.ensure_schema!
      ActiveRecord::Schema.define do
        create_table(:vehicles, if_not_exists: true) do |t|
          t.string(:display_name, null: false)
          t.boolean(:pinned, null: false, default: false)
          t.string(:gasbuddy_uuid)
        end

        create_table(:fillups, if_not_exists: true) do |t|
          t.references(:vehicle, null: false)
          t.string(:filled_at, null: false)
          t.float(:total_cost,       null: false)
          t.float(:quantity_liters,  null: false)
          t.float(:unit_price_cents, null: false)
          t.integer(:odometer)
          t.float(:l_per_100km)
          t.string(:gasbuddy_entry_uuid)
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

        # GasBuddy auto-sync. Single-row table — the integration is
        # per-installation, not per-user.
        create_table(:gasbuddy_settings, if_not_exists: true) do |t|
          t.string(:username)         # encrypted
          t.string(:password)         # encrypted
          t.string(:flaresolverr_url) # plain (UI-configured runtime URL)
          t.text(:cookies_json)       # encrypted (Faraday cookie jar dump)
          t.string(:user_agent)
          t.string(:csrf_token)
          t.string(:cookies_fetched_at)
          t.boolean(:auto_sync_enabled, null: false, default: true)
          t.string(:last_sync_at)
          t.text(:last_sync_status)   # JSON
          t.string(
            :created_at,
            null: false,
            default: -> { "(strftime('%Y-%m-%dT%H:%M:%fZ','now'))" },
          )
          t.string(:updated_at)
        end

        # Per-sync audit log. status: running|ok|failed|partial.
        create_table(:sync_runs, if_not_exists: true) do |t|
          t.string(:started_at, null: false)
          t.string(:finished_at)
          t.string(:trigger, null: false) # "scheduled" | "manual"
          t.string(:status, null: false)
          t.integer(:vehicles_synced,   null: false, default: 0)
          t.integer(:fillups_inserted,  null: false, default: 0)
          t.integer(:fillups_linked,    null: false, default: 0)
          t.integer(:fillups_skipped,   null: false, default: 0)
          t.text(:error_message)
          t.index(:started_at, name: "idx_sync_runs_started_at")
        end

        # Ordered messages emitted by a single sync run.
        create_table(:sync_log_entries, if_not_exists: true) do |t|
          t.references(:sync_run, null: false, foreign_key: { on_delete: :cascade })
          t.string(:level, null: false) # info|warn|error
          t.text(:message, null: false)
          t.text(:detail) # optional JSON
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
    # re-running on every boot is a no-op once converged. Runs AFTER
    # ensure_schema!, so any partial-index creation lives here — at this
    # point the columns it depends on are guaranteed to exist.
    def self.migrate!
      conn = ActiveRecord::Base.connection

      unless conn.column_exists?(:vehicles, :pinned)
        conn.add_column(:vehicles, :pinned, :boolean, null: false, default: false)
        conn.execute("UPDATE vehicles SET pinned = 1")
      end

      [:slug, :csv_vehicle].each do |col|
        conn.remove_column(:vehicles, col) if conn.column_exists?(:vehicles, col)
      end

      conn.add_column(:vehicles, :gasbuddy_uuid, :string) unless conn.column_exists?(:vehicles, :gasbuddy_uuid)
      conn.add_column(:fillups,  :gasbuddy_entry_uuid, :string) unless conn.column_exists?(:fillups, :gasbuddy_entry_uuid)

      add_unique_partial_index(:vehicles, :gasbuddy_uuid, "idx_vehicles_gasbuddy_uuid")
      add_unique_partial_index(:fillups,  :gasbuddy_entry_uuid, "idx_fillups_gasbuddy_entry_uuid")

      [:partial_fill, :fuel_type, :location, :city, :notes].each do |col|
        conn.remove_column(:fillups, col) if conn.column_exists?(:fillups, col)
      end

      Vehicle.reset_column_information
      Fillup.reset_column_information
      GasbuddySetting.reset_column_information
      SyncRun.reset_column_information
      SyncLogEntry.reset_column_information
    end

    # SQLite supports `CREATE UNIQUE INDEX ... WHERE` (partial index);
    # ActiveRecord's `add_index ... where:` maps to it cleanly. Skip when
    # the index already exists so re-runs are idempotent.
    def self.add_unique_partial_index(table, column, name)
      return if ActiveRecord::Base.connection.index_name_exists?(table, name)

      ActiveRecord::Base.connection.add_index(
        table, column, unique: true, where: "#{column} IS NOT NULL", name: name
      )
    end
  end
end
