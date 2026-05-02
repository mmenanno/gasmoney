# frozen_string_literal: true

require "sinatra/base"
require "securerandom"
require "time"

require_relative "lib/db"
require_relative "lib/importer"
require_relative "lib/calculator"

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
  end
end
