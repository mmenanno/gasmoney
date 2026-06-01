# frozen_string_literal: true

require "test_helper"

class FillupTest < ActiveSupport::TestCase
  setup do
    @vehicle = create_vehicle
  end

  test "with_economy excludes rows with nil fuel_economy" do
    create_fillup(vehicle: @vehicle, filled_at: "2026-01-01T00:00:00Z", fuel_economy: 9.0, odometer: 1)
    create_fillup(vehicle: @vehicle, filled_at: "2026-01-02T00:00:00Z", fuel_economy: nil, odometer: 2)

    assert_equal(1, GasMoney::Fillup.with_economy.count)
  end

  test "for_date matches by calendar date, ignoring time-of-day" do
    create_fillup(vehicle: @vehicle, filled_at: "2026-03-15T18:30:00Z", odometer: 1)

    assert_equal(1, GasMoney::Fillup.for_date(Date.parse("2026-03-15")).count)
    assert_equal(0, GasMoney::Fillup.for_date(Date.parse("2026-03-16")).count)
  end

  test "before_date / after_date partition fillups around a target date" do
    create_fillup(vehicle: @vehicle, filled_at: "2026-01-01T00:00:00Z", odometer: 1)
    create_fillup(vehicle: @vehicle, filled_at: "2026-02-01T00:00:00Z", odometer: 2)
    create_fillup(vehicle: @vehicle, filled_at: "2026-03-01T00:00:00Z", odometer: 3)

    target = Date.parse("2026-02-01")

    assert_equal(1, GasMoney::Fillup.before_date(target).count)
    assert_equal(1, GasMoney::Fillup.after_date(target).count)
  end

  test "recent_first orders newest fillup first" do
    older = create_fillup(vehicle: @vehicle, filled_at: "2026-01-01T00:00:00Z", odometer: 1)
    newer = create_fillup(vehicle: @vehicle, filled_at: "2026-02-01T00:00:00Z", odometer: 2)

    assert_equal([newer, older], GasMoney::Fillup.recent_first.to_a)
  end

  test "cost_per_distance combines fuel_economy and unit_price_cents" do
    fillup = create_fillup(vehicle: @vehicle, fuel_economy: 10.0, unit_price_cents: 150.0)

    # 10 L/100km × $1.50/L = $0.15/km.
    assert_in_delta(0.15, fillup.cost_per_distance, 0.0001)
  end

  test "cost_per_distance is nil when fuel_economy is missing" do
    fillup = create_fillup(vehicle: @vehicle, fuel_economy: nil)

    assert_nil(fillup.cost_per_distance)
  end

  test "new fillups default to metric + CAD" do
    fillup = create_fillup(vehicle: @vehicle)

    assert_equal("metric", fillup.unit_system)
    assert_equal("CAD",    fillup.currency)
  end

  test "validates unit_system inclusion" do
    fillup = GasMoney::Fillup.new(
      vehicle: @vehicle,
      filled_at: "2026-01-15T12:00:00Z",
      total_cost: 50.0,
      quantity: 40.0,
      unit_price_cents: 125.0,
      odometer: 1,
      fuel_economy: 9.0,
      unit_system: "imperial",
    )

    refute_predicate(fillup, :valid?)
    assert_includes(fillup.errors[:unit_system].join, "included")
  end

  test "validates currency inclusion" do
    fillup = GasMoney::Fillup.new(
      vehicle: @vehicle,
      filled_at: "2026-01-15T12:00:00Z",
      total_cost: 50.0,
      quantity: 40.0,
      unit_price_cents: 125.0,
      odometer: 1,
      fuel_economy: 9.0,
      currency: "EUR",
    )

    refute_predicate(fillup, :valid?)
    assert_includes(fillup.errors[:currency].join, "included")
  end

  test "accepts us_customary + USD" do
    fillup = create_fillup(
      vehicle: @vehicle,
      unit_system: "us_customary",
      currency: "USD",
      quantity: 10.0,
      fuel_economy: 27.4,
      unit_price_cents: 450.0,
    )

    assert_equal("us_customary", fillup.unit_system)
    assert_equal("USD",          fillup.currency)
  end

  test "distinct_currency_count reflects the set of currencies in fillups" do
    assert_equal(0, GasMoney::Fillup.distinct_currency_count)
    create_fillup(vehicle: @vehicle)

    assert_equal(1, GasMoney::Fillup.distinct_currency_count)
    create_fillup(vehicle: @vehicle, odometer: 51_000, filled_at: "2026-02-15T12:00:00Z", currency: "USD")

    assert_equal(2, GasMoney::Fillup.distinct_currency_count)
  end
end
