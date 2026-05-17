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
      # GasBuddy's GraphQL has two `fuelLogs` queries:
      #   - `myVehicle(guid:).fuelLogs(limit:)` — used by the SSR
      #     vehicle profile page, defaults to current-year only.
      #   - root `fuelLogs(vehicleGuid:, limit:, year:)` — used by
      #     the dedicated fuel-log-book page, accepts an explicit
      #     year filter (passed as a String, not Int).
      # Using the root query with an explicit year is the only way
      # to backfill prior years; we use it for both modes for
      # consistency. `year: nil` returns the current-year subset
      # (same as the recent-only sync used to do); `year: "2024"`
      # returns just 2024's fillups, and so on.
      FUEL_LOGS_OPERATION = "GetFuelLogs"
      FUEL_LOGS_LIMIT     = 1000

      # How far back to walk during a backfill, and how many
      # consecutive empty years to tolerate before stopping. A
      # vehicle bought mid-year may have a gap year (e.g., owned
      # 2018 + 2020 but no fillups logged in 2019), so a single
      # empty year shouldn't terminate the walk.
      BACKFILL_OLDEST_YEAR    = 2010
      BACKFILL_EMPTY_YEAR_CAP = 2

      FUEL_LOGS_QUERY = <<~GQL
        query GetFuelLogs($guid: ID!, $limit: Int, $year: String) {
          fuelLogs(vehicleGuid: $guid, limit: $limit, year: $year) {
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
      GQL

      LINK_DATE_WINDOW_HOURS = 36 # ± hours around the remote filled_at

      MODES = [:recent, :backfill].freeze

      def self.run(trigger:, mode: :recent, logger: nil)
        new(trigger: trigger, mode: mode, logger: logger).run
      end

      def initialize(trigger:, mode: :recent, logger: nil)
        raise ArgumentError, "Unknown sync mode: #{mode.inspect}" unless MODES.include?(mode)

        @trigger = trigger
        @mode    = mode
        @logger  = logger
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
        label = @mode == :backfill ? "Backfilling" : "Syncing"
        @run.log!(:info, "#{label} #{vehicle.display_name} (#{vehicle.gasbuddy_uuid})")

        existing_uuids = Fillup.where(vehicle_id: vehicle.id).where.not(gasbuddy_entry_uuid: nil).pluck(:gasbuddy_entry_uuid).to_set

        years = @mode == :backfill ? backfill_year_walk : [nil]
        total_seen = 0
        empty_streak = 0

        years.each do |year|
          details = fetch_year(vehicle, year)
          total_seen += details.size

          if @mode == :backfill && year
            if details.empty?
              empty_streak += 1
              break if empty_streak >= BACKFILL_EMPTY_YEAR_CAP

              next
            else
              empty_streak = 0
            end
          end

          details.each do |detail|
            if existing_uuids.include?(detail.uuid)
              increment(:fillups_skipped)
              next
            end
            process_detail(vehicle, detail)
            existing_uuids << detail.uuid
          end
        end

        @run.log!(:info, "Vehicle #{vehicle.display_name}: #{total_seen} remote entries seen")
        @run.update!(vehicles_synced: @run.vehicles_synced + 1)
      rescue StandardError => e
        @run.log!(:error, "Sync failed for #{vehicle.display_name}", detail: { error: e.message, klass: e.class.name })
      end

      def fetch_year(vehicle, year)
        variables = { guid: vehicle.gasbuddy_uuid, limit: FUEL_LOGS_LIMIT, year: year }
        response = @client.post_graphql(
          operation_name: FUEL_LOGS_OPERATION,
          variables:      variables,
          query:          FUEL_LOGS_QUERY,
        )
        details = Scraper.parse_fuel_logs(JSON.parse(response.body))
        @run.log!(:info, "  #{year || "recent"}: #{details.size} entries") if @mode == :backfill
        details
      end

      def backfill_year_walk
        current = Time.now.utc.year
        # Walk newest → oldest. Newest first means the visible
        # progress in the log starts with familiar years and works
        # backwards rather than diving into unrelated ancient data
        # before the operator gets any feedback.
        current.downto(BACKFILL_OLDEST_YEAR).map(&:to_s)
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
          quantity:            detail.quantity || 0,
          unit_price_cents:    detail.unit_price_cents || 0,
          odometer:            detail.odometer,
          fuel_economy:        detail.fuel_economy,
          gasbuddy_entry_uuid: detail.uuid,
          unit_system:         detail.unit_system,
          currency:            detail.currency,
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
        Fillup.find_linkable_remote(
          vehicle_id:   vehicle.id,
          filled_at:    detail.filled_at,
          quantity:     detail.quantity,
          unit_system:  detail.unit_system,
          currency:     detail.currency,
          window_hours: LINK_DATE_WINDOW_HOURS,
        )
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
