# frozen_string_literal: true

require "test_helper"

class FillupTest < ActiveSupport::TestCase
  setup do
    @vehicle = create_vehicle
  end

  test "with_economy excludes rows with nil l_per_100km" do
    create_fillup(vehicle: @vehicle, filled_at: "2026-01-01T00:00:00Z", l_per_100km: 9.0, odometer: 1)
    create_fillup(vehicle: @vehicle, filled_at: "2026-01-02T00:00:00Z", l_per_100km: nil, odometer: 2)

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

  test "cost_per_km combines l_per_100km and unit_price_cents" do
    fillup = create_fillup(vehicle: @vehicle, l_per_100km: 10.0, unit_price_cents: 150.0)

    # 10 L/100km × $1.50/L = $0.15/km.
    assert_in_delta(0.15, fillup.cost_per_km, 0.0001)
  end

  test "cost_per_km is nil when l_per_100km is missing" do
    fillup = create_fillup(vehicle: @vehicle, l_per_100km: nil)

    assert_nil(fillup.cost_per_km)
  end
end
