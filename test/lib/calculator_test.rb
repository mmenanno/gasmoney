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
        distance:   100,
      )
    end
  end

  test "exact-date match uses that fillup's values directly" do
    create_fillup(
      vehicle:          @vehicle,
      filled_at:        "2026-04-17T16:00:04Z",
      total_cost:       105.45,
      quantity:         64.733,
      unit_price_cents: 162.9,
      odometer:         111_616,
      fuel_economy:     10.3,
    )

    estimate = GasMoney::Calculator.estimate(
      vehicle_id: @vehicle.id,
      trip_date:  "2026-04-17",
      distance:   250,
    )

    # 10.3 L/100km × 250 km / 100 = 25.75 L; × $1.629/L = $41.95.
    assert_equal("exact",  estimate.calc_method)
    assert_in_delta(41.95, estimate.estimated_cost)
    assert_in_delta(25.75, estimate.fuel_used, 0.001)
    assert_in_delta(162.9, estimate.unit_price_cents, 0.001)
  end

  test "between two fillups averages their fuel economy and unit price" do
    create_fillup(
      vehicle:          @vehicle,
      filled_at:        "2025-12-12T17:00:00Z",
      unit_price_cents: 122.3,
      odometer:         87_533,
      fuel_economy:     8.9,
    )
    create_fillup(
      vehicle:          @vehicle,
      filled_at:        "2025-12-18T16:00:00Z",
      unit_price_cents: 114.9,
      odometer:         87_911,
      fuel_economy:     10.8,
    )

    estimate = GasMoney::Calculator.estimate(
      vehicle_id: @vehicle.id,
      trip_date:  "2025-12-15",
      distance:   200,
    )

    # avg L/100km = 9.85, avg ¢/L = 118.6 → liters = 19.7, cost = $23.36.
    assert_equal("between", estimate.calc_method)
    assert_in_delta(118.6,  estimate.unit_price_cents, 0.001)
    assert_in_delta(9.85,   estimate.fuel_economy,     0.001)
    assert_in_delta(19.7,   estimate.fuel_used,        0.001)
    assert_in_delta(23.36, estimate.estimated_cost)
  end

  test "after_latest uses the most recent fillup with valid economy" do
    create_fillup(
      vehicle:          @vehicle,
      filled_at:        "2026-04-17T16:00:00Z",
      unit_price_cents: 162.9,
      odometer:         111_616,
      fuel_economy:     10.3,
    )

    estimate = GasMoney::Calculator.estimate(
      vehicle_id: @vehicle.id,
      trip_date:  "2026-05-01",
      distance:   100,
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
      fuel_economy:     10.3,
    )

    estimate = GasMoney::Calculator.estimate(
      vehicle_id: @vehicle.id,
      trip_date:  "2024-01-01",
      distance:   100,
    )

    assert_equal("before_earliest", estimate.calc_method)
  end

  test "between falls back to whichever side has economy data when one side is missing" do
    create_fillup(
      vehicle:          @vehicle,
      filled_at:        "2026-01-01T00:00:00Z",
      unit_price_cents: 100.0,
      odometer:         1,
      fuel_economy:     nil,
    )
    create_fillup(
      vehicle:          @vehicle,
      filled_at:        "2026-03-01T00:00:00Z",
      unit_price_cents: 130.0,
      odometer:         2,
      fuel_economy:     8.0,
    )

    estimate = GasMoney::Calculator.estimate(
      vehicle_id: @vehicle.id,
      trip_date:  "2026-02-01",
      distance:   100,
    )

    # No "before" with valid economy exists, so fall back to the "after"
    # fillup. That maps to the before_earliest path.
    assert_equal("before_earliest", estimate.calc_method)
    assert_in_delta(8.0, estimate.fuel_economy)
    assert_in_delta(130.0, estimate.unit_price_cents)
  end

  test "exact match falls through to between when its fuel_economy is nil" do
    create_fillup(
      vehicle:          @vehicle,
      filled_at:        "2026-01-01T00:00:00Z",
      unit_price_cents: 100.0,
      odometer:         1,
      fuel_economy:     8.0,
    )
    # Same-day fillup but a partial fill — no fuel economy reading, so the
    # estimator must skip it and fall through to the surrounding fillups.
    create_fillup(
      vehicle:          @vehicle,
      filled_at:        "2026-02-01T12:00:00Z",
      unit_price_cents: 110.0,
      odometer:         2,
      fuel_economy:     nil,
    )
    create_fillup(
      vehicle:          @vehicle,
      filled_at:        "2026-03-01T00:00:00Z",
      unit_price_cents: 120.0,
      odometer:         3,
      fuel_economy:     10.0,
    )

    estimate = GasMoney::Calculator.estimate(
      vehicle_id: @vehicle.id,
      trip_date:  "2026-02-01",
      distance:   100,
    )

    refute_equal("exact", estimate.calc_method)
  end

  test "persists every estimate as a TripSearch row" do
    create_fillup(vehicle: @vehicle, fuel_economy: 10.0, unit_price_cents: 150.0)

    assert_difference("GasMoney::TripSearch.count", 1) do
      GasMoney::Calculator.estimate(
        vehicle_id: @vehicle.id,
        trip_date:  "2026-01-15",
        distance:   100,
      )
    end
  end

  test "cost_per_distance_summary returns nils when there are no fillups with economy" do
    summary = GasMoney::Calculator.cost_per_distance_summary(@vehicle)

    assert_nil(summary.latest)
    assert_nil(summary.average5)
    assert_equal(0, summary.sample_size)
  end

  test "cost_per_distance_summary uses the latest fillup with economy and the 5-fillup average" do
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
        fuel_economy:     econ,
        unit_price_cents: price,
        odometer:         1_000 + i,
      )
    end

    summary = GasMoney::Calculator.cost_per_distance_summary(@vehicle)

    # Latest row: 13.0 L/100km × $1.70/L = $0.221/km.
    assert_in_delta(0.221, summary.latest, 0.0001)
    # Five most recent rows (Feb-Jun) average to 0.167/km.
    assert_in_delta(0.167, summary.average5, 0.001)
    assert_equal(5, summary.sample_size)
    assert_equal("metric", summary.unit_system)
    assert_equal("CAD",    summary.currency)
  end

  test "us_customary fillup estimate uses miles ÷ MPG math and stores trip-input system" do
    create_fillup(
      vehicle:          @vehicle,
      filled_at:        "2026-04-17T16:00:04Z",
      unit_system:      "us_customary",
      currency:         "USD",
      quantity:         10.0,
      fuel_economy:     30.0,                       # MPG
      unit_price_cents: 400.0,                      # ¢/gal → $4.00/gal
      odometer:         60_000,
    )

    estimate = GasMoney::Calculator.estimate(
      vehicle_id:  @vehicle.id,
      trip_date:   "2026-04-17",
      distance:    100,                             # 100 mi
      unit_system: :us_customary,
    )

    # 100 mi ÷ 30 MPG = 3.333 gal × $4.00/gal = $13.33
    assert_in_delta(13.33, estimate.estimated_cost, 0.01)
    assert_in_delta(3.333, estimate.fuel_used, 0.001)
    assert_equal("us_customary", estimate.unit_system)
    assert_equal("USD",          estimate.currency)
  end

  test "metric trip input with us_customary fillup converts distance before math and stores trip-input units" do
    create_fillup(
      vehicle:          @vehicle,
      filled_at:        "2026-04-17T16:00:04Z",
      unit_system:      "us_customary",
      currency:         "USD",
      quantity:         10.0,
      fuel_economy:     30.0,                       # MPG
      unit_price_cents: 400.0,                      # ¢/gal
      odometer:         60_000,
    )

    estimate = GasMoney::Calculator.estimate(
      vehicle_id:  @vehicle.id,
      trip_date:   "2026-04-17",
      distance:    160.934,                         # 160.934 km = 100 mi
      unit_system: :metric,
    )

    # 100 mi-equivalent ÷ 30 MPG = 3.333 gal × $4.00/gal = $13.33 USD.
    assert_in_delta(13.33, estimate.estimated_cost, 0.01)
    # fuel_used stored in trip-input units (litres): 3.333 gal × 3.78541 = 12.62 L
    assert_in_delta(12.62, estimate.fuel_used, 0.05)
    assert_equal("metric", estimate.unit_system)
    assert_equal("USD",    estimate.currency)
  end

  test "between with mismatched (unit_system, currency) tuples falls back to the calendar-newer fillup" do
    create_fillup(
      vehicle:          @vehicle,
      filled_at:        "2026-01-01T00:00:00Z",
      unit_system:      "metric",
      currency:         "CAD",
      unit_price_cents: 160.0,
      fuel_economy:     9.0,
      odometer:         1,
    )
    create_fillup(
      vehicle:          @vehicle,
      filled_at:        "2026-03-01T00:00:00Z",
      unit_system:      "us_customary",
      currency:         "USD",
      unit_price_cents: 400.0,
      fuel_economy:     30.0,
      odometer:         2,
    )

    estimate = GasMoney::Calculator.estimate(
      vehicle_id:  @vehicle.id,
      trip_date:   "2026-02-01",
      distance:    100,
      unit_system: :us_customary,
    )

    # The newer (after) fillup is us_customary, so the picker discards
    # averaging and uses just that one. before_earliest is the marker
    # we use when the older candidate is dropped.
    assert_equal("before_earliest", estimate.calc_method)
    assert_equal("USD", estimate.currency)
  end

  test "cost_per_distance_summary filters out fillups whose (unit_system, currency) differs from the latest" do
    create_fillup(vehicle: @vehicle, filled_at: "2026-01-01T00:00:00Z", odometer: 1, fuel_economy: 9.0)   # metric/CAD
    create_fillup(vehicle: @vehicle, filled_at: "2026-02-01T00:00:00Z", odometer: 2, fuel_economy: 8.0)   # metric/CAD
    create_fillup(
      vehicle:      @vehicle,
      filled_at:    "2026-03-01T00:00:00Z",
      odometer:     3,
      unit_system:  "us_customary",
      currency:     "USD",
      quantity:     10.0,
      fuel_economy: 30.0,
      unit_price_cents: 400.0,
    )

    summary = GasMoney::Calculator.cost_per_distance_summary(@vehicle)

    assert_equal("us_customary", summary.unit_system)
    assert_equal("USD",          summary.currency)
    assert_equal(1, summary.sample_size, "summary should only include the lone us_customary/USD fillup")
  end
end
