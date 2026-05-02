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

  test "parse_fuel_log_list pulls id + filledAt pairs" do
    payload = {
      "data" => {
        "vehicleFuelLogs" => [
          { "id" => "entry-1", "filledAt" => "2026-04-17T16:00:04Z" },
          { "id" => "entry-2", "filledAt" => "2026-04-04T18:57:39Z" },
        ],
      },
    }
    entries = GasMoney::GasBuddy::Scraper.parse_fuel_log_list(payload)

    assert_equal(["entry-1", "entry-2"], entries.map(&:uuid))
  end

  test "parse_fuel_log_detail normalises fields and converts dollar prices to cents" do
    payload = {
      "data" => {
        "vehicleFuelLog" => {
          "id" => "entry-1",
          "filledAt" => "2026-04-17T16:00:04Z",
          "totalCost" => "105.45",
          "quantity" => "64.733",
          "unitPrice" => "1.629",
          "odometer" => "111616",
          "fuelEconomy" => "10.3",
        },
      },
    }
    detail = GasMoney::GasBuddy::Scraper.parse_fuel_log_detail(payload)

    assert_equal("entry-1", detail.uuid)
    assert_in_delta(105.45,  detail.total_cost,       0.001)
    assert_in_delta(64.733,  detail.quantity_liters,  0.001)
    assert_in_delta(162.9,   detail.unit_price_cents, 0.001)
    assert_equal(111_616,    detail.odometer)
    assert_in_delta(10.3,    detail.l_per_100km, 0.001)
  end

  test "parse_fuel_log_detail returns nil when the entry payload is empty" do
    assert_nil(GasMoney::GasBuddy::Scraper.parse_fuel_log_detail({ "data" => {} }))
  end
end
