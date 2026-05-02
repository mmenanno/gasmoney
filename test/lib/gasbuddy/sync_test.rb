# frozen_string_literal: true

require "test_helper"
require "gasbuddy/sync"

class GasBuddySyncTest < ActiveSupport::TestCase
  setup do
    @setting = GasMoney::GasbuddySetting.current
    @setting.update!(
      username: "halorrr",
      password: "secret",
      flaresolverr_url: "http://flare.test",
      cookies_json: [{ name: "_gb", value: "abc", domain: ".gasbuddy.com" }].to_json,
      user_agent: "Mozilla/5.0 (test)",
      csrf_token: "csrf-1",
      cookies_fetched_at: Time.now.utc.iso8601,
    )

    @vehicle = GasMoney::Vehicle.create!(
      display_name: "Test Sedan",
      gasbuddy_uuid: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
    )

    stub_vehicle_list
  end

  test "creates a SyncRun with status=ok when there are no remote entries" do
    stub_fuel_logs([])

    run = GasMoney::GasBuddy::Sync.run(trigger: "manual")

    assert_equal("ok", run.status)
    assert_equal(1, run.vehicles_synced)
    assert_equal(0, run.fillups_inserted)
    assert_equal(0, run.fillups_linked)
    assert_equal(0, run.fillups_skipped)
  end

  test "inserts fillups for new entries" do
    stub_fuel_logs([entry_payload("entry-1")])

    run = GasMoney::GasBuddy::Sync.run(trigger: "manual")

    assert_equal("ok", run.status)
    assert_equal(1, run.fillups_inserted)
    fillup = GasMoney::Fillup.find_by(gasbuddy_entry_uuid: "entry-1")

    assert_equal(@vehicle.id, fillup.vehicle_id)
    assert_in_delta(10.3, fillup.l_per_100km, 0.001)
  end

  test "links existing manual fillups to remote entries within tolerance" do
    # Pre-existing manual entry (CSV-imported, no gasbuddy uuid).
    existing = GasMoney::Fillup.create!(
      vehicle_id:        @vehicle.id,
      filled_at:         "2026-04-17T15:00:00Z",   # within 36h window
      total_cost:        105.45,
      quantity_liters:   64.7,                     # within 0.5L tolerance
      unit_price_cents:  162.9,
      odometer:          111_616,
      l_per_100km:       10.3,
    )

    stub_fuel_logs([entry_payload("entry-1")])

    run = GasMoney::GasBuddy::Sync.run(trigger: "manual")

    assert_equal(0, run.fillups_inserted)
    assert_equal(1, run.fillups_linked)
    assert_equal("entry-1", existing.reload.gasbuddy_entry_uuid)
  end

  test "skips entries already synced by gasbuddy_entry_uuid" do
    GasMoney::Fillup.create!(
      vehicle_id:          @vehicle.id,
      filled_at:           "2026-04-17T16:00:04Z",
      total_cost:          105.45,
      quantity_liters:     64.733,
      unit_price_cents:    162.9,
      gasbuddy_entry_uuid: "entry-1",
    )

    stub_fuel_logs([entry_payload("entry-1")])

    run = GasMoney::GasBuddy::Sync.run(trigger: "manual")

    assert_equal(1, run.fillups_skipped)
    assert_equal(0, run.fillups_inserted)
    assert_equal(0, run.fillups_linked)
  end

  test "marks the run failed when credentials are missing" do
    @setting.update!(username: nil, password: nil)

    run = GasMoney::GasBuddy::Sync.run(trigger: "manual")

    assert_equal("failed", run.status)
    assert_match(/credentials/, run.error_message)
  end

  test "skips remote vehicles that aren't linked locally" do
    @vehicle.update!(gasbuddy_uuid: nil)
    stub_fuel_logs([])

    run = GasMoney::GasBuddy::Sync.run(trigger: "manual")

    assert_equal("ok", run.status)
    assert_equal(0, run.vehicles_synced)
  end

  private

  def stub_vehicle_list
    stub_request(:get, "https://www.gasbuddy.com/account/vehicles")
      .to_return(status: 200, body: File.read(File.expand_path("../../fixtures/gasbuddy_vehicles.html", __dir__)))
  end

  def stub_fuel_logs(results)
    stub_request(:post, "https://www.gasbuddy.com/graphql")
      .with(body: hash_including("operationName" => "MyVehicleFuelLogs"))
      .to_return(
        status: 200,
        body: JSON.generate(
          "data" => {
            "myVehicle" => {
              "guid" => @vehicle.gasbuddy_uuid,
              "fuelLogs" => { "results" => results },
            },
          },
        ),
        headers: { "Content-Type" => "application/json" },
      )
  end

  def entry_payload(uuid, purchase_date: "2026-04-17T16:00:04Z", total_cost: "105.45",
    amount_filled: "64.733", price_per_unit: "162.9", odometer: "111616",
    economy: "10.3")
    {
      "guid" => uuid,
      "purchaseDate" => purchase_date,
      "totalCost" => total_cost,
      "amountFilled" => amount_filled,
      "pricePerUnit" => price_per_unit,
      "odometer" => odometer,
      "fuelEconomy" => {
        "status" => economy ? "complete" : "missingPrevious",
        "fuelEconomy" => economy ? { "fuelEconomy" => economy, "fuelEconomyUnits" => "L/100km" } : nil,
      },
    }
  end
end
