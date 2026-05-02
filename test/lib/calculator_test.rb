# frozen_string_literal: true

require "test_helper"

class CalculatorTest < ActiveSupport::TestCase
  setup do
    @vehicle = create_vehicle
  end

  test "raises InsufficientData when the vehicle has no fillups" do
    assert_raises(GasMoney::Calculator::InsufficientData) do
      GasMoney::Calculator.estimate(
        vehicle_id: @vehicle.id,
        trip_date:  "2026-05-01",
        kilometers: 100,
      )
    end
  end

  test "exact-date match uses that fillup's values directly" do
    create_fillup(
      vehicle:          @vehicle,
      filled_at:        "2026-04-17T16:00:04Z",
      total_cost:       105.45,
      quantity_liters:  64.733,
      unit_price_cents: 162.9,
      odometer:         111_616,
      l_per_100km:      10.3,
    )

    estimate = GasMoney::Calculator.estimate(
      vehicle_id: @vehicle.id,
      trip_date:  "2026-04-17",
      kilometers: 250,
    )

    # 10.3 L/100km × 250 km / 100 = 25.75 L; × $1.629/L = $41.95.
    assert_equal("exact",  estimate.calc_method)
    assert_in_delta(41.95, estimate.estimated_cost)
    assert_in_delta(25.75, estimate.liters_used, 0.001)
    assert_in_delta(162.9, estimate.unit_price_cents, 0.001)
  end

  test "between two fillups averages their fuel economy and unit price" do
    create_fillup(
      vehicle:          @vehicle,
      filled_at:        "2025-12-12T17:00:00Z",
      unit_price_cents: 122.3,
      odometer:         87_533,
      l_per_100km:      8.9,
    )
    create_fillup(
      vehicle:          @vehicle,
      filled_at:        "2025-12-18T16:00:00Z",
      unit_price_cents: 114.9,
      odometer:         87_911,
      l_per_100km:      10.8,
    )

    estimate = GasMoney::Calculator.estimate(
      vehicle_id: @vehicle.id,
      trip_date:  "2025-12-15",
      kilometers: 200,
    )

    # avg L/100km = 9.85, avg ¢/L = 118.6 → liters = 19.7, cost = $23.36.
    assert_equal("between", estimate.calc_method)
    assert_in_delta(118.6,  estimate.unit_price_cents, 0.001)
    assert_in_delta(9.85,   estimate.l_per_100km,      0.001)
    assert_in_delta(19.7,   estimate.liters_used,      0.001)
    assert_in_delta(23.36, estimate.estimated_cost)
  end

  test "after_latest uses the most recent fillup with valid economy" do
    create_fillup(
      vehicle:          @vehicle,
      filled_at:        "2026-04-17T16:00:00Z",
      unit_price_cents: 162.9,
      odometer:         111_616,
      l_per_100km:      10.3,
    )

    estimate = GasMoney::Calculator.estimate(
      vehicle_id: @vehicle.id,
      trip_date:  "2026-05-01",
      kilometers: 100,
    )

    assert_equal("after_latest", estimate.calc_method)
    assert_in_delta(16.78, estimate.estimated_cost)
  end

  test "before_earliest uses the oldest fillup with valid economy" do
    create_fillup(
      vehicle:          @vehicle,
      filled_at:        "2026-04-17T16:00:00Z",
      unit_price_cents: 162.9,
      odometer:         111_616,
      l_per_100km:      10.3,
    )

    estimate = GasMoney::Calculator.estimate(
      vehicle_id: @vehicle.id,
      trip_date:  "2024-01-01",
      kilometers: 100,
    )

    assert_equal("before_earliest", estimate.calc_method)
  end

  test "between falls back to whichever side has economy data when one side is missing" do
    create_fillup(
      vehicle:          @vehicle,
      filled_at:        "2026-01-01T00:00:00Z",
      unit_price_cents: 100.0,
      odometer:         1,
      l_per_100km:      nil,
    )
    create_fillup(
      vehicle:          @vehicle,
      filled_at:        "2026-03-01T00:00:00Z",
      unit_price_cents: 130.0,
      odometer:         2,
      l_per_100km:      8.0,
    )

    estimate = GasMoney::Calculator.estimate(
      vehicle_id: @vehicle.id,
      trip_date:  "2026-02-01",
      kilometers: 100,
    )

    # No "before" with valid economy exists, so fall back to the "after"
    # fillup. That maps to the before_earliest path.
    assert_equal("before_earliest", estimate.calc_method)
    assert_in_delta(8.0, estimate.l_per_100km)
    assert_in_delta(130.0, estimate.unit_price_cents)
  end

  test "exact match falls through to between when its l_per_100km is nil" do
    create_fillup(
      vehicle:          @vehicle,
      filled_at:        "2026-01-01T00:00:00Z",
      unit_price_cents: 100.0,
      odometer:         1,
      l_per_100km:      8.0,
    )
    # Same-day fillup but a partial fill — no fuel economy reading, so the
    # estimator must skip it and fall through to the surrounding fillups.
    create_fillup(
      vehicle:          @vehicle,
      filled_at:        "2026-02-01T12:00:00Z",
      unit_price_cents: 110.0,
      odometer:         2,
      l_per_100km:      nil,
    )
    create_fillup(
      vehicle:          @vehicle,
      filled_at:        "2026-03-01T00:00:00Z",
      unit_price_cents: 120.0,
      odometer:         3,
      l_per_100km:      10.0,
    )

    estimate = GasMoney::Calculator.estimate(
      vehicle_id: @vehicle.id,
      trip_date:  "2026-02-01",
      kilometers: 100,
    )

    refute_equal("exact", estimate.calc_method)
  end

  test "persists every estimate as a TripSearch row" do
    create_fillup(vehicle: @vehicle, l_per_100km: 10.0, unit_price_cents: 150.0)

    assert_difference("GasMoney::TripSearch.count", 1) do
      GasMoney::Calculator.estimate(
        vehicle_id: @vehicle.id,
        trip_date:  "2026-01-15",
        kilometers: 100,
      )
    end
  end

  test "cost_per_km_summary returns nils when there are no fillups with economy" do
    summary = GasMoney::Calculator.cost_per_km_summary(@vehicle)

    assert_nil(summary.latest)
    assert_nil(summary.average5)
    assert_equal(0, summary.sample_size)
  end

  test "cost_per_km_summary uses the latest fillup with economy and the 5-fillup average" do
    # Six rows so the 5-fillup window cleanly excludes the oldest one.
    [
      ["2026-01-01T00:00:00Z", 8.0,  120.0],
      ["2026-02-01T00:00:00Z", 9.0,  130.0],
      ["2026-03-01T00:00:00Z", 10.0, 140.0],
      ["2026-04-01T00:00:00Z", 11.0, 150.0],
      ["2026-05-01T00:00:00Z", 12.0, 160.0],
      ["2026-06-01T00:00:00Z", 13.0, 170.0],
    ].each_with_index do |(date, econ, price), i|
      create_fillup(
        vehicle:          @vehicle,
        filled_at:        date,
        l_per_100km:      econ,
        unit_price_cents: price,
        odometer:         1_000 + i,
      )
    end

    summary = GasMoney::Calculator.cost_per_km_summary(@vehicle)

    # Latest row: 13.0 L/100km × $1.70/L = $0.221/km.
    assert_in_delta(0.221, summary.latest, 0.0001)
    # Five most recent rows (Feb-Jun) average to 0.167/km.
    assert_in_delta(0.167, summary.average5, 0.001)
    assert_equal(5, summary.sample_size)
  end
end
