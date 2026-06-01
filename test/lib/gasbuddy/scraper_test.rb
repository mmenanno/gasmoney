# frozen_string_literal: true

require "test_helper"
require "gasbuddy/scraper"

class GasBuddyScraperTest < ActiveSupport::TestCase
  FIXTURE_HTML = File.read(File.expand_path("../../fixtures/gasbuddy_vehicles.html", __dir__))

  test "parse_vehicles extracts uuid + name pairs from anchor links" do
    vehicles = GasMoney::GasBuddy::Scraper.parse_vehicles(FIXTURE_HTML)
    uuids = vehicles.map { |v| v[:uuid] }

    assert_equal(3, vehicles.size)
    assert_includes(uuids, "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
    assert_includes(uuids, "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
    assert_includes(uuids, "cccccccc-cccc-cccc-cccc-cccccccccccc")
  end

  test "parse_vehicles falls back to img alt when anchor text is empty" do
    vehicle = GasMoney::GasBuddy::Scraper.parse_vehicles(FIXTURE_HTML)
      .find { |v| v[:uuid].start_with?("bbbb") }

    assert_equal("Test Wagon", vehicle[:name])
  end

  test "parse_vehicles dedups multiple anchors per uuid by keeping the longest name" do
    vehicle = GasMoney::GasBuddy::Scraper.parse_vehicles(FIXTURE_HTML)
      .find { |v| v[:uuid].start_with?("cccc") }

    assert_equal("Long Truck Display Name", vehicle[:name])
  end

  test "parse_vehicles ignores non-uuid links" do
    vehicles = GasMoney::GasBuddy::Scraper.parse_vehicles(FIXTURE_HTML)

    refute(vehicles.any? { |v| v[:name].include?("Should Not Match") })
  end

  test "parse_fuel_logs flattens results into DetailEntry rows with normalised fields" do
    payload = {
      "data" => {
        "fuelLogs" => {
          "results" => [
            {
              "guid" => "entry-1",
              "purchaseDate" => "2026-04-17T16:00:04Z",
              "totalCost" => "105.45",
              "amountFilled" => "64.733",
              "pricePerUnit" => "162.9",
              "odometer" => "111616",
              "fuelEconomy" => {
                "status" => "complete",
                "fuelEconomy" => { "fuelEconomy" => "10.3", "fuelEconomyUnits" => "L/100km" },
              },
            },
            {
              "guid" => "entry-2",
              "purchaseDate" => "2026-04-04T18:57:39Z",
              "totalCost" => "52.99",
              "amountFilled" => "32.5",
              "pricePerUnit" => "163.1",
              "odometer" => "111200",
              "fuelEconomy" => { "status" => "missingPrevious", "fuelEconomy" => nil },
            },
          ],
        },
      },
    }

    entries = GasMoney::GasBuddy::Scraper.parse_fuel_logs(payload)

    assert_equal(["entry-1", "entry-2"], entries.map(&:uuid))
    assert_in_delta(105.45,  entries[0].total_cost,       0.001)
    assert_in_delta(64.733,  entries[0].quantity,         0.001)
    assert_in_delta(162.9,   entries[0].unit_price_cents, 0.001)
    assert_equal(111_616,    entries[0].odometer)
    assert_in_delta(10.3,    entries[0].fuel_economy, 0.001)
    assert_nil(entries[1].fuel_economy, "missingPrevious entries should surface nil fuel economy")
  end

  test "parse_fuel_logs tags metric entries with unit_system + currency" do
    payload = {
      "data" => {
        "fuelLogs" => {
          "results" => [
            {
              "guid" => "entry-1",
              "purchaseDate" => "2026-04-17T16:00:04Z",
              "totalCost" => "105.45",
              "amountFilled" => "64.733",
              "pricePerUnit" => "162.9",
              "odometer" => "111616",
              "fuelEconomy" => {
                "status" => "complete",
                "fuelEconomy" => { "fuelEconomy" => "10.3", "fuelEconomyUnits" => "L/100km" },
              },
            },
          ],
        },
      },
    }

    entry = GasMoney::GasBuddy::Scraper.parse_fuel_logs(payload).first

    assert_equal("metric", entry.unit_system)
    assert_equal("CAD",    entry.currency)
  end

  test "parse_fuel_logs tags an MPG entry as us_customary + USD" do
    payload = {
      "data" => {
        "fuelLogs" => {
          "results" => [
            {
              "guid" => "entry-us",
              "purchaseDate" => "2026-04-17T16:00:04Z",
              "totalCost" => "42.55",
              "amountFilled" => "9.401",
              "pricePerUnit" => "452.6",
              "odometer" => "60214",
              "fuelEconomy" => {
                "status" => "complete",
                "fuelEconomy" => { "fuelEconomy" => "27.4", "fuelEconomyUnits" => "MPG" },
              },
            },
          ],
        },
      },
    }

    entry = GasMoney::GasBuddy::Scraper.parse_fuel_logs(payload).first

    assert_equal("us_customary", entry.unit_system)
    assert_equal("USD",          entry.currency)
    assert_in_delta(27.4,        entry.fuel_economy, 0.001)
  end

  test "parse_fuel_logs returns [] when the response carries no results" do
    assert_equal([], GasMoney::GasBuddy::Scraper.parse_fuel_logs({ "data" => { "fuelLogs" => nil } }))
    assert_equal([], GasMoney::GasBuddy::Scraper.parse_fuel_logs({ "data" => {} }))
  end
end
