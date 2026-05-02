# frozen_string_literal: true

require "json"

require_relative "client"
require_relative "scraper"
require_relative "../models/sync_run"

module GasMoney
  module GasBuddy
    # Orchestrates a full sync pass: refresh cookies if needed, fetch
    # the vehicle list, then for each linked vehicle fetch fuel-log
    # entries and reconcile them into the local fillups table.
    #
    # Reconciliation rules per remote entry:
    #   1. If a fillup with that gasbuddy_entry_uuid already exists →
    #      skip (counter: fillups_skipped).
    #   2. Else find an existing fillup with NO gasbuddy_entry_uuid that
    #      matches by date + quantity within tolerance → set its uuid
    #      (counter: fillups_linked). This adopts manually-imported or
    #      CSV-imported rows so we don't end up with duplicates.
    #   3. Else insert a fresh fillup with the uuid set (counter:
    #      fillups_inserted).
    #
    # Every step writes a SyncLogEntry so the UI can replay what
    # happened — including any partial failures — without losing
    # context.
    class Sync
      # Single-shot GraphQL query that pulls a vehicle's fuel logs in
      # the shape GasBuddy's own React app uses. Schema discovered by
      # inspecting `window.__APOLLO_STATE__` after navigating to a
      # vehicle's account page: the root query is `myVehicle(guid:)`
      # returning a `Vehicle` whose `fuelLogs(limit:)` returns a
      # `FuelLogResults { results: [FuelLog] }` connection. Each
      # `FuelLog` carries every field we need (timestamp, cost,
      # quantity, unit price, odometer, fuel economy with its own
      # status enum), so a single query is enough — no separate
      # detail fetch.
      FUEL_LOGS_OPERATION = "MyVehicleFuelLogs"
      FUEL_LOGS_LIMIT     = 1000

      FUEL_LOGS_QUERY = <<~GQL
        query MyVehicleFuelLogs($guid: ID!, $limit: Int) {
          myVehicle(guid: $guid) {
            guid
            fuelLogs(limit: $limit) {
              results {
                guid
                purchaseDate
                totalCost
                amountFilled
                pricePerUnit
                odometer
                fuelType
                status
                fuelEconomy {
                  status
                  fuelEconomy {
                    fuelEconomy
                    fuelEconomyUnits
                  }
                }
                location {
                  name
                }
              }
            }
          }
        }
      GQL

      LINK_QUANTITY_TOLERANCE = 0.5    # litres
      LINK_DATE_WINDOW_HOURS  = 36     # ± hours around the remote filled_at

      def self.run(trigger:, logger: nil)
        new(trigger: trigger, logger: logger).run
      end

      def initialize(trigger:, logger: nil)
        @trigger = trigger
        @logger = logger
      end

      def run
        @run = SyncRun.create!(
          started_at: Time.now.utc.iso8601,
          trigger:    @trigger,
          status:     "running",
        )
        @setting = GasbuddySetting.current
        @client = Client.new(
          setting: @setting,
          # Pipe Client log output into the SyncRun log so the auth
          # flow ("Launching headless Chromium", "Login complete —
          # captured N cookies") is visible in the UI.
          logger:  SyncRunLogger.new(@run, @logger),
        )

        do_run
      rescue StandardError => e
        finalize_failed!(e)
      ensure
        @setting&.update!(last_sync_at: Time.now.utc.iso8601, last_sync_status: status_payload.to_json)
      end

      # Adapter that lets Client#log(:info, "...") write to both the
      # SyncRun's persisted log and any optional out-of-band logger
      # (e.g. STDERR for local development).
      class SyncRunLogger
        def initialize(run, fallback = nil)
          @run = run
          @fallback = fallback
        end

        def info(msg)  = forward(:info, msg)
        def warn(msg)  = forward(:warn, msg)
        def error(msg) = forward(:error, msg)
        def debug(msg) = forward(:info, msg)

        private

        def forward(level, msg)
          @run.log!(level, msg.to_s)
          @fallback&.public_send(level, msg)
        end
      end

      private

      def do_run
        fail_run!("GasBuddy credentials are not set") unless @setting.credentials_present?

        # Sync no longer fetches the GasBuddy garage on every run —
        # that's a separate "Refresh garage" action. Iterate the
        # already-linked vehicles only, and short-circuit if none.
        ignored_uuids = GasbuddyRemoteVehicle.ignored.pluck(:uuid).to_set
        linked = Vehicle.where.not(gasbuddy_uuid: nil).reject { |v| ignored_uuids.include?(v.gasbuddy_uuid) }

        if linked.empty?
          @run.log!(:warn, "No vehicles are linked to a GasBuddy UUID — link one on /sync first")
          finalize!(status: "ok")
          return @run
        end

        linked.each { |vehicle| sync_vehicle(vehicle) }

        finalize!(status: any_errors? ? "partial" : "ok")
      end

      def sync_vehicle(vehicle)
        @run.log!(:info, "Syncing #{vehicle.display_name} (#{vehicle.gasbuddy_uuid})")
        response = @client.post_graphql(
          operation_name: FUEL_LOGS_OPERATION,
          variables:      { guid: vehicle.gasbuddy_uuid, limit: FUEL_LOGS_LIMIT },
          query:          FUEL_LOGS_QUERY,
        )
        details = Scraper.parse_fuel_logs(JSON.parse(response.body))
        @run.log!(:info, "Vehicle #{vehicle.display_name}: #{details.size} remote entries")
        @run.update!(vehicles_synced: @run.vehicles_synced + 1)

        existing_uuids = Fillup.where(vehicle_id: vehicle.id).where.not(gasbuddy_entry_uuid: nil).pluck(:gasbuddy_entry_uuid)
        existing_uuid_set = existing_uuids.to_set

        details.each do |detail|
          if existing_uuid_set.include?(detail.uuid)
            increment(:fillups_skipped)
            next
          end

          process_detail(vehicle, detail)
        end
      rescue StandardError => e
        @run.log!(:error, "Sync failed for #{vehicle.display_name}", detail: { error: e.message, klass: e.class.name })
      end

      def process_detail(vehicle, detail)
        existing = find_linkable(vehicle, detail)
        if existing
          existing.update!(gasbuddy_entry_uuid: detail.uuid)
          increment(:fillups_linked)
          @run.log!(:info, "Linked existing fillup to GasBuddy entry #{detail.uuid}")
          return
        end

        Fillup.create!(
          vehicle_id:          vehicle.id,
          filled_at:           detail.filled_at,
          total_cost:          detail.total_cost || 0,
          quantity_liters:     detail.quantity_liters || 0,
          unit_price_cents:    detail.unit_price_cents || 0,
          odometer:            detail.odometer,
          l_per_100km:         detail.l_per_100km,
          gasbuddy_entry_uuid: detail.uuid,
        )
        increment(:fillups_inserted)
      rescue ActiveRecord::RecordNotUnique
        # Race against a parallel/manual import that just inserted the
        # same uuid; treat as already-skipped.
        increment(:fillups_skipped)
      rescue StandardError => e
        @run.log!(:error, "Couldn't reconcile entry #{detail.uuid}", detail: { error: e.message })
      end

      # Looks for an existing fillup that probably represents the same
      # event as the incoming GasBuddy entry — same vehicle, similar
      # timestamp, similar quantity. Restricted to fillups that don't
      # already carry a gasbuddy_entry_uuid so we don't overwrite a
      # link from a previous sync.
      def find_linkable(vehicle, detail)
        return if detail.filled_at.nil? || detail.quantity_liters.nil?

        target_time = Time.parse(detail.filled_at)
        window_start = (target_time - (LINK_DATE_WINDOW_HOURS * 3_600)).iso8601
        window_end   = (target_time + (LINK_DATE_WINDOW_HOURS * 3_600)).iso8601
        qty_min = detail.quantity_liters - LINK_QUANTITY_TOLERANCE
        qty_max = detail.quantity_liters + LINK_QUANTITY_TOLERANCE

        Fillup.where(vehicle_id: vehicle.id, gasbuddy_entry_uuid: nil)
          .where(filled_at: window_start..window_end)
          .where(quantity_liters: qty_min..qty_max)
          .first
      rescue ArgumentError
        nil
      end

      def increment(field)
        @run.update!(field => @run.read_attribute(field) + 1)
      end

      def any_errors?
        @run.sync_log_entries.exists?(level: ["error", "warn"])
      end

      def fail_run!(message)
        @run.log!(:error, message)
        @run.update!(status: "failed", finished_at: Time.now.utc.iso8601, error_message: message)
        raise Error, message
      end

      def finalize!(status:)
        @run.update!(status: status, finished_at: Time.now.utc.iso8601)
        @run
      end

      def finalize_failed!(error)
        @run.update!(
          status:        "failed",
          finished_at:   Time.now.utc.iso8601,
          error_message: error.message,
        )
        @run.log!(:error, "Sync aborted: #{error.message}", detail: { klass: error.class.name })
        @run
      end

      def status_payload
        return {} unless @run

        {
          status: @run.status,
          finished_at: @run.finished_at,
          vehicles_synced: @run.vehicles_synced,
          fillups_inserted: @run.fillups_inserted,
          fillups_linked: @run.fillups_linked,
          fillups_skipped: @run.fillups_skipped,
          error_message: @run.error_message,
        }
      end

      class Error < StandardError; end
    end
  end
end
