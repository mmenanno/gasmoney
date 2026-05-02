# frozen_string_literal: true

require "test_helper"
require "rack/test"
require "app"

class AppTest < ActiveSupport::TestCase
  include Rack::Test::Methods

  def app
    @app ||= begin
      GasMoney::App.set(:host_authorization, { permitted_hosts: [] })
      GasMoney::App
    end
  end

  test "GET /health returns 200 ok" do
    get "/health"

    assert_equal(200, last_response.status)
    assert_match(/"status":"ok"/, last_response.body)
  end

  test "GET / on a fresh DB shows the no-vehicles welcome state" do
    get "/"

    assert_equal(200, last_response.status)
    assert_includes(last_response.body, "adding a vehicle")
  end

  test "POST /vehicles creates a vehicle and pins it when requested" do
    assert_difference("GasMoney::Vehicle.count", 1) do
      post "/vehicles", { display_name: "Test Sedan", pinned: "1" }
    end
    vehicle = GasMoney::Vehicle.last

    assert_equal("Test Sedan", vehicle.display_name)
    assert(vehicle.pinned)
  end

  test "POST /vehicles/:id/toggle_pin flips the pinned flag" do
    vehicle = create_vehicle(pinned: false)

    post "/vehicles/#{vehicle.id}/toggle_pin"

    assert(vehicle.reload.pinned)

    post "/vehicles/#{vehicle.id}/toggle_pin"

    refute(vehicle.reload.pinned)
  end

  test "POST /vehicles/:id/delete removes the vehicle and its dependents" do
    vehicle = create_vehicle
    create_fillup(vehicle: vehicle)

    post "/vehicles/#{vehicle.id}/delete"

    assert_nil(GasMoney::Vehicle.find_by(id: vehicle.id))
    assert_equal(0, GasMoney::Fillup.count)
  end

  test "POST /calculate runs an estimate and shows it on the dashboard" do
    vehicle = create_vehicle(pinned: true)
    create_fillup(
      vehicle:          vehicle,
      filled_at:        "2026-04-17T16:00:04Z",
      unit_price_cents: 162.9,
      l_per_100km:      10.3,
    )

    post "/calculate", { vehicle_id: vehicle.id, trip_date: "2026-04-17", kilometers: "250" }

    assert_predicate(last_response, :redirect?)
    follow_redirect!

    assert_includes(last_response.body, "$41.95")
    assert_includes(last_response.body, "exact match")
  end

  test "POST /calculate with no fillups flashes a friendly error" do
    vehicle = create_vehicle

    post "/calculate", { vehicle_id: vehicle.id, trip_date: "2026-04-17", kilometers: "100" }
    follow_redirect!

    assert_includes(last_response.body, "no fillups for vehicle")
  end

  test "POST /import requires a vehicle selection" do
    create_vehicle # so the import page renders the form
    file = Rack::Test::UploadedFile.new(StringIO.new(""), "text/csv", original_filename: "x.csv")

    post "/import", { file: file }

    assert_predicate(last_response, :redirect?)
    follow_redirect!

    assert_includes(last_response.body, "Pick the vehicle")
  end

  test "POST /saved_trips creates a saved trip" do
    assert_difference("GasMoney::SavedTrip.count", 1) do
      post "/saved_trips", { name: "Commute", base_kilometers: "30", round_trip: "1" }
    end
    trip = GasMoney::SavedTrip.last

    assert_equal("Commute", trip.name)
    assert_equal(1,         trip.round_trip)
  end

  test "POST /saved_trips/:id/delete removes the saved trip" do
    trip = GasMoney::SavedTrip.create!(name: "Commute", base_kilometers: 30)

    post "/saved_trips/#{trip.id}/delete"

    assert_nil(GasMoney::SavedTrip.find_by(id: trip.id))
  end

  test "GET /vehicles/:id/fillups renders the fillup-management page" do
    vehicle = create_vehicle

    get "/vehicles/#{vehicle.id}/fillups"

    assert_equal(200, last_response.status)
    assert_includes(last_response.body, "Add a fillup")
  end

  test "POST /vehicles/:id/fillups creates a fillup with the supplied values" do
    vehicle = create_vehicle

    assert_difference("GasMoney::Fillup.count", 1) do
      post "/vehicles/#{vehicle.id}/fillups", {
        filled_at: "2026-04-17T16:00",
        total_cost: "50.00",
        quantity_liters: "40.0",
        unit_price_cents: "125.0",
        odometer: "100000",
        l_per_100km: "9.0",
      }
    end
    fillup = GasMoney::Fillup.last

    assert_equal(vehicle.id, fillup.vehicle_id)
    assert_in_delta(9.0, fillup.l_per_100km)
  end

  test "POST /vehicles/:id/fillups treats blank l_per_100km as a partial fill" do
    vehicle = create_vehicle

    post "/vehicles/#{vehicle.id}/fillups", {
      filled_at: "2026-04-17T16:00",
      total_cost: "50.00",
      quantity_liters: "40.0",
      unit_price_cents: "125.0",
      odometer: "100000",
    }
    fillup = GasMoney::Fillup.last

    assert_nil(fillup.l_per_100km)
  end

  test "POST /sync/flaresolverr/test surfaces a typed error when the host is unreachable" do
    stub_request(:get, "http://flare.test/").to_raise(Faraday::ConnectionFailed.new("connection refused"))

    post "/sync/flaresolverr/test", { flaresolverr_url: "http://flare.test" }

    assert_predicate(last_response, :redirect?)
    follow_redirect!

    assert_match(/FlareSolverr error/, last_response.body)
  end

  test "POST /sync/flaresolverr/test reports the version on a healthy instance" do
    stub_request(:get, "http://flare.test/")
      .to_return(
        status: 200,
        body: JSON.generate(msg: "FlareSolverr is ready!", version: "3.3.21"),
        headers: { "Content-Type" => "application/json" },
      )

    post "/sync/flaresolverr/test", { flaresolverr_url: "http://flare.test" }
    follow_redirect!

    assert_match(/Connected to FlareSolverr v3\.3\.21/, last_response.body)
  end

  test "POST /fillups/:id/delete removes the fillup" do
    vehicle = create_vehicle
    fillup = create_fillup(vehicle: vehicle)

    post "/fillups/#{fillup.id}/delete"

    assert_nil(GasMoney::Fillup.find_by(id: fillup.id))
  end

  test "GET /?trip=ID prefills the calculator with the saved trip" do
    create_vehicle
    trip = GasMoney::SavedTrip.create!(name: "Errands", base_kilometers: 42, round_trip: 1)

    get "/", { trip: trip.id }

    assert_includes(last_response.body, "Errands")
    assert_includes(last_response.body, 'value="42"')
    assert_includes(last_response.body, "checked")
  end
end
