# frozen_string_literal: true

require "sinatra/base"
require "securerandom"
require "time"

require_relative "lib/db"
require_relative "lib/importer"
require_relative "lib/calculator"
require_relative "lib/gasbuddy/sync"
require_relative "lib/gasbuddy/garage"
require_relative "lib/scheduler"

module GasMoney
  DEV_SESSION_SECRET = "gasmoney-local-dev-secret-do-not-use-in-prod-#{"x" * 64}".freeze
  VERSION = File.read(File.expand_path("VERSION", __dir__)).strip.freeze

  class App < Sinatra::Base
    enable :sessions
    set :session_secret, ENV.fetch("SESSION_SECRET", DEV_SESSION_SECRET)
    set :views, File.expand_path("views", __dir__)
    set :public_folder, File.expand_path("public", __dir__)
    set :method_override, true

    configure do
      DB.connect
      # Scheduler ticks the daily auto-sync. Skipped when running tests
      # (RACK_ENV=test) so suites don't accidentally hit the network.
      Scheduler.start! unless ENV["RACK_ENV"] == "test"
    end

    after { ActiveRecord::Base.connection_handler.clear_active_connections! }

    # The PWA manifest needs application/manifest+json for some browsers
    # (Firefox in particular) to honour `<link rel="manifest">`. Sinatra
    # serves .webmanifest as text/plain by default.
    mime_type :webmanifest, "application/manifest+json"

    helpers do
      def vehicles                  = Vehicle.ordered
      def vehicles_pinned_first     = Vehicle.pinned_first
      def pinned_vehicles           = Vehicle.pinned.ordered
      def vehicle(id)               = Vehicle.find_by(id: id)

      def dashboard_summaries
        pinned_vehicles.map do |v|
          {
            vehicle: v,
            summary: Calculator.cost_per_km_summary(v),
            latest: Calculator.latest_fillup(v),
          }
        end
      end

      def recent_searches(limit: 25)
        TripSearch.includes(:vehicle).order(created_at: :desc).limit(limit)
      end

      def saved_trips = SavedTrip.order(:name)

      def find_saved_trip(id)
        return if id.nil? || id.to_s.empty?

        SavedTrip.find_by(id: Integer(id))
      rescue ArgumentError
        nil
      end

      def fmt_money(amount) = format("$%.2f", amount.to_f)

      def fmt_per_km(amount)
        return "—" if amount.nil?

        format("$%.3f", amount.to_f)
      end

      def fmt_date(value)
        return "" if value.nil? || value.to_s.empty?

        Date.parse(value.to_s).strftime("%Y-%m-%d")
      end

      def fmt_method(method)
        {
          "exact" => "exact match",
          "between" => "between fillups",
          "after_latest" => "after latest fillup",
          "before_earliest" => "before earliest fillup",
        }.fetch(method, method)
      end

      def fmt_unit_price(cents)
        return "—" if cents.nil?

        format("$%.3f/L", cents.to_f / 100.0)
      end

      def flash
        msg = session.delete(:flash)
        msg.is_a?(Hash) ? msg : nil
      end

      def set_flash(kind, message)
        session[:flash] = { kind: kind, message: message }
      end

      def h(value) = Rack::Utils.escape_html(value.to_s)

      # Maps a fillup form submission to the column types Fillup expects.
      # `filled_at` arrives as a `<input type="datetime-local">` value
      # ("YYYY-MM-DDTHH:MM"); we normalise it to UTC ISO 8601 so the
      # importer's dedup key shape stays consistent.
      def build_fillup_attrs(form)
        filled_at_raw = form["filled_at"].to_s.strip
        filled_at = filled_at_raw.empty? ? Time.now.utc : Time.parse(filled_at_raw).utc

        {
          filled_at: filled_at.iso8601,
          total_cost: Float(form["total_cost"]),
          quantity_liters: Float(form["quantity_liters"]),
          unit_price_cents: Float(form["unit_price_cents"]),
          odometer: form["odometer"].to_s.strip.empty? ? nil : Integer(form["odometer"]),
          l_per_100km: form["l_per_100km"].to_s.strip.empty? ? nil : Float(form["l_per_100km"]),
        }
      end
    end

    get "/health" do
      content_type :json
      '{"status":"ok"}'
    end

    get "/" do
      @result = session.delete(:last_estimate)
      @selected_trip = find_saved_trip(params["trip"])
      erb :index
    end

    post "/calculate" do
      vehicle_id = Integer(params["vehicle_id"])
      trip_date  = params["trip_date"].to_s.strip
      kilometers = params["kilometers"].to_s.strip
      round_trip = params["round_trip"] == "1"

      if trip_date.empty? || kilometers.empty?
        set_flash(:error, "Trip date and kilometres are required.")
        redirect "/"
      end

      begin
        actual_km = Float(kilometers)
        actual_km *= 2 if round_trip
        estimate = Calculator.estimate(
          vehicle_id: vehicle_id,
          trip_date: trip_date,
          kilometers: actual_km,
        )
        session[:last_estimate] = estimate.attributes.symbolize_keys.merge(
          vehicle_name: estimate.vehicle.display_name,
        )
      rescue Calculator::InsufficientData => e
        set_flash(:error, "Can't estimate: #{e.message}.")
      rescue ArgumentError, ActiveRecord::RecordNotFound => e
        set_flash(:error, "Invalid input: #{e.message}.")
      end

      redirect "/"
    end

    post "/searches/:id/delete" do
      TripSearch.where(id: params["id"].to_i).delete_all
      redirect "/"
    end

    # ---- Vehicles ----

    get "/vehicles" do
      erb :vehicles
    end

    post "/vehicles" do
      begin
        Vehicle.create!(
          display_name: params["display_name"].to_s.strip,
          pinned:       params["pinned"] == "1",
        )
        set_flash(:success, "Vehicle added.")
      rescue ActiveRecord::RecordInvalid => e
        set_flash(:error, "Couldn't save: #{e.record.errors.full_messages.join(", ")}.")
      end
      redirect "/vehicles"
    end

    post "/vehicles/:id/update" do
      vehicle = Vehicle.find_by(id: params["id"].to_i)
      unless vehicle
        set_flash(:error, "Vehicle not found.")
        redirect "/vehicles"
      end

      begin
        vehicle.update!(
          display_name: params["display_name"].to_s.strip,
          pinned:       params["pinned"] == "1",
        )
        set_flash(:success, "Vehicle updated.")
      rescue ActiveRecord::RecordInvalid => e
        set_flash(:error, "Couldn't save: #{e.record.errors.full_messages.join(", ")}.")
      end
      redirect "/vehicles"
    end

    post "/vehicles/:id/toggle_pin" do
      vehicle = Vehicle.find_by(id: params["id"].to_i)
      vehicle&.update!(pinned: !vehicle.pinned)
      redirect(params["return_to"].to_s.start_with?("/") ? params["return_to"] : "/vehicles")
    end

    post "/vehicles/:id/delete" do
      Vehicle.where(id: params["id"].to_i).destroy_all
      redirect "/vehicles"
    end

    # ---- Fillups (per-vehicle) ----

    get "/vehicles/:id/fillups" do
      @vehicle = Vehicle.find_by(id: params["id"].to_i)
      halt(404, "Vehicle not found") unless @vehicle

      erb :fillups
    end

    post "/vehicles/:id/fillups" do
      vehicle = Vehicle.find_by(id: params["id"].to_i)
      halt(404, "Vehicle not found") unless vehicle

      attrs = build_fillup_attrs(params)
      Fillup.create!(attrs.merge(vehicle: vehicle))
      set_flash(:success, "Fillup added.")
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
      set_flash(:error, "Couldn't save: #{e.message}.")
    rescue ArgumentError, TypeError => e
      set_flash(:error, "Invalid input: #{e.message}.")
    ensure
      redirect("/vehicles/#{params["id"].to_i}/fillups")
    end

    post "/fillups/:id/delete" do
      fillup = Fillup.find_by(id: params["id"].to_i)
      vehicle_id = fillup&.vehicle_id
      fillup&.destroy
      redirect(vehicle_id ? "/vehicles/#{vehicle_id}/fillups" : "/vehicles")
    end

    # ---- Import ----

    get "/import" do
      erb :import
    end

    post "/import" do
      upload = params["file"]
      vehicle = Vehicle.find_by(id: params["vehicle_id"].to_i)

      unless upload.is_a?(Hash) && upload[:tempfile]
        set_flash(:error, "Pick a CSV file to import.")
        redirect "/import"
      end

      unless vehicle
        set_flash(:error, "Pick the vehicle these logs are for.")
        redirect "/import"
      end

      result = Importer.import(upload[:tempfile], vehicle: vehicle)
      set_flash(
        :success,
        "Imported #{upload[:filename]} into #{vehicle.display_name}: " \
        "#{result.inserted} new, #{result.duplicates} duplicates skipped, " \
        "#{result.skipped} rows skipped.",
      )
      redirect "/"
    end

    # ---- Saved trips ----

    get "/saved_trips" do
      erb :saved_trips
    end

    post "/saved_trips" do
      attrs = {
        name: params["name"].to_s.strip,
        base_kilometers: params["base_kilometers"],
        round_trip: params["round_trip"] == "1" ? 1 : 0,
      }

      begin
        SavedTrip.create!(attrs)
        set_flash(:success, "Saved trip \"#{attrs[:name]}\".")
      rescue ActiveRecord::RecordInvalid => e
        set_flash(:error, "Couldn't save: #{e.record.errors.full_messages.join(", ")}.")
      end

      redirect "/saved_trips"
    end

    post "/saved_trips/:id/delete" do
      SavedTrip.where(id: params["id"].to_i).delete_all
      redirect "/saved_trips"
    end

    # ---- GasBuddy auto-sync ----

    helpers do
      def gasbuddy_setting = GasbuddySetting.current

      def gasbuddy_remote_vehicles
        GasbuddyRemoteVehicle.ordered.to_a
      end

      def fmt_relative(time_str)
        return "—" if time_str.to_s.empty?

        delta = Time.now.utc - Time.parse(time_str)
        return "just now" if delta < 30
        return "#{(delta / 60).floor}m ago" if delta < 3_600
        return "#{(delta / 3_600).floor}h ago" if delta < 86_400

        Date.parse(time_str).strftime("%Y-%m-%d")
      rescue ArgumentError
        time_str
      end
    end

    get "/sync" do
      @setting = gasbuddy_setting
      @recent_runs = SyncRun.recent.includes(:sync_log_entries).limit(10)
      @remote_vehicles = gasbuddy_remote_vehicles
      @local_vehicles = Vehicle.ordered
      erb :sync
    end

    get "/sync/runs/:id.json" do
      content_type :json
      run = SyncRun.find_by(id: params["id"].to_i)
      halt(404, '{"error":"not found"}') unless run

      JSON.generate(
        id:                run.id,
        status:            run.status,
        trigger:           run.trigger,
        started_at:        run.started_at,
        finished_at:       run.finished_at,
        duration_seconds:  run.duration_seconds,
        vehicles_synced:   run.vehicles_synced,
        fillups_inserted:  run.fillups_inserted,
        fillups_linked:    run.fillups_linked,
        fillups_skipped:   run.fillups_skipped,
        error_message:     run.error_message,
        log: run.sync_log_entries.map do |e|
          { level: e.level, message: e.message, detail: e.parsed_detail, at: e.created_at }
        end,
      )
    end

    post "/sync/credentials" do
      setting = gasbuddy_setting
      username = params["username"].to_s.strip
      password = params["password"].to_s

      if username.empty? || password.empty?
        set_flash(:error, "Username and password are required.")
        redirect "/sync"
      end

      setting.update!(username: username, password: password)
      set_flash(:success, "GasBuddy credentials saved.")
      redirect "/sync"
    end

    post "/sync/credentials/clear" do
      setting = gasbuddy_setting
      setting.update!(
        username: nil,
        password: nil,
        cookies_json: nil,
        user_agent: nil,
        csrf_token: nil,
        cookies_fetched_at: nil,
      )
      set_flash(:success, "Credentials cleared.")
      redirect "/sync"
    end

    post "/sync/auto" do
      setting = gasbuddy_setting
      setting.update!(auto_sync_enabled: params["auto_sync_enabled"] == "1")
      redirect "/sync"
    end

    post "/sync/vehicles/link" do
      remote_uuid = params["remote_uuid"].to_s
      target_id   = params["vehicle_id"].to_s

      if remote_uuid.empty?
        set_flash(:error, "Missing remote vehicle UUID.")
        redirect "/sync"
      end

      # Reset any prior link so the remote↔local relation stays
      # one-to-one. "" = unlinked, anything else = local Vehicle id.
      Vehicle.where(gasbuddy_uuid: remote_uuid).update_all(gasbuddy_uuid: nil)

      if target_id.empty?
        set_flash(:success, "Unlinked.")
      else
        Vehicle.where(id: target_id.to_i).update_all(gasbuddy_uuid: remote_uuid)
        set_flash(:success, "Vehicle linked.")
      end
      redirect "/sync"
    end

    post "/sync/vehicles/ignore" do
      remote_uuid = params["remote_uuid"].to_s
      remote = GasbuddyRemoteVehicle.find_by(uuid: remote_uuid)
      if remote
        # Ignoring also clears any link — sync wouldn't touch it
        # anyway, and leaving a stale link around makes the linking
        # UI lie about the row's state.
        Vehicle.where(gasbuddy_uuid: remote_uuid).update_all(gasbuddy_uuid: nil)
        remote.update!(ignored: true)
        set_flash(:success, "Ignored #{remote.display_name}. Sync will skip it.")
      else
        set_flash(:error, "Remote vehicle not found.")
      end
      redirect "/sync"
    end

    post "/sync/vehicles/restore" do
      remote_uuid = params["remote_uuid"].to_s
      remote = GasbuddyRemoteVehicle.find_by(uuid: remote_uuid)
      if remote
        remote.update!(ignored: false)
        set_flash(:success, "Restored #{remote.display_name}.")
      else
        set_flash(:error, "Remote vehicle not found.")
      end
      redirect "/sync"
    end

    post "/sync/garage/refresh" do
      setting = gasbuddy_setting
      unless setting.credentials_present?
        set_flash(:error, "Save GasBuddy credentials first.")
        redirect("/sync")
      end

      result = GasMoney::GasBuddy::Garage.refresh!
      set_flash(:success, "Found #{result.total} #{result.total == 1 ? "vehicle" : "vehicles"} on GasBuddy (#{result.inserted} new).")
      redirect("/sync")
    rescue StandardError => e
      set_flash(:error, "Couldn't refresh garage: #{e.message}")
      redirect("/sync")
    end

    post "/sync/run" do
      setting = gasbuddy_setting

      unless setting.credentials_present?
        set_flash(:error, "Save GasBuddy credentials first.")
        redirect "/sync"
      end

      Scheduler.run_now_async(trigger: "manual")
      set_flash(:success, "Sync started.")
      redirect "/sync"
    end

    post "/sync/runs/clear" do
      # Clears the entire sync activity ledger, but only the rows
      # that have already finished. A live sync (running status) is
      # left in place so its writer doesn't try to update a row that
      # vanished mid-run.
      destroyed = SyncRun.where.not(status: "running").destroy_all.size
      set_flash(:success, "Cleared #{destroyed} sync #{destroyed == 1 ? "run" : "runs"}.")
      redirect "/sync"
    end
  end
end
