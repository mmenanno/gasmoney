# frozen_string_literal: true

require "active_record"
require_relative "client"
require_relative "scraper"

module GasMoney
  module GasBuddy
    # Refreshes the persisted GasBuddy garage. Logs into GasBuddy via
    # the bundled headless Chromium, scrapes /account/vehicles, and
    # upserts each remote vehicle into the gasbuddy_remote_vehicles
    # table. Decoupled from Sync so the user can pull a fresh garage
    # listing — typically before linking a newly-added vehicle —
    # without burning a fillup-sync round-trip on it.
    class Garage
      Result = Struct.new(:total, :inserted, :updated, keyword_init: true)

      def self.refresh!(logger: nil)
        new(logger: logger).refresh!
      end

      def initialize(logger: nil)
        @logger = logger
      end

      def refresh!
        setting = GasbuddySetting.current
        raise "GasBuddy credentials are not set" unless setting.credentials_present?

        client = Client.new(setting: setting, logger: @logger)
        html = client.get("/account/vehicles").body
        remote = Scraper.parse_vehicles(html)
        now = Time.now.utc.iso8601

        inserted = 0
        updated = 0
        remote.each do |entry|
          row = GasbuddyRemoteVehicle.find_or_initialize_by(uuid: entry[:uuid])
          if row.new_record?
            row.assign_attributes(display_name: entry[:name], last_seen_at: now)
            row.save!
            inserted += 1
          else
            row.update!(display_name: entry[:name], last_seen_at: now)
            updated += 1
          end
        end

        Result.new(total: remote.size, inserted: inserted, updated: updated)
      end
    end
  end
end
