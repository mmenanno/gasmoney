# frozen_string_literal: true

require "test_helper"
require "units"

class UnitsTest < ActiveSupport::TestCase
  test "convert returns nil for nil input regardless of kind" do
    GasMoney::Units::KINDS.each do |kind|
      assert_nil(GasMoney::Units.convert(nil, from: :metric, to: :us_customary, kind: kind))
    end
  end

  test "convert short-circuits when from == to and returns a float" do
    result = GasMoney::Units.convert(42, from: :metric, to: :metric, kind: :volume)

    assert_in_delta(42.0, result, 1e-9)
    assert_kind_of(Float, result)
  end

  test "volume converts on the US gallon constant" do
    assert_in_delta(1.0,      GasMoney::Units.convert(3.78541, from: :metric,       to: :us_customary, kind: :volume), 1e-6)
    assert_in_delta(3.78541,  GasMoney::Units.convert(1.0,     from: :us_customary, to: :metric,       kind: :volume), 1e-6)
  end

  test "distance converts on the mile constant" do
    assert_in_delta(1.0,     GasMoney::Units.convert(1.60934, from: :metric,       to: :us_customary, kind: :distance), 1e-6)
    assert_in_delta(1.60934, GasMoney::Units.convert(1.0,     from: :us_customary, to: :metric,       kind: :distance), 1e-6)
  end

  test "economy is a reciprocal — 25 MPG ↔ ~9.408 L/100km" do
    assert_in_delta(9.4086,  GasMoney::Units.convert(25.0,   from: :us_customary, to: :metric,       kind: :economy), 1e-3)
    assert_in_delta(27.3505, GasMoney::Units.convert(8.6,    from: :metric,       to: :us_customary, kind: :economy), 1e-3)
  end

  test "price_per_volume converts on the gallon constant in inverse direction to volume" do
    # 100 ¢/L × 3.78541 L/gal = 378.541 ¢/gal
    assert_in_delta(378.541, GasMoney::Units.convert(100.0, from: :metric,       to: :us_customary, kind: :price_per_volume), 1e-3)
    assert_in_delta(100.0,   GasMoney::Units.convert(378.541, from: :us_customary, to: :metric,     kind: :price_per_volume), 1e-3)
  end

  test "cost_per_distance uses the mile constant in inverse direction to distance" do
    # $0.15/km × 1.60934 km/mi = $0.241/mi
    assert_in_delta(0.241, GasMoney::Units.convert(0.15, from: :metric, to: :us_customary, kind: :cost_per_distance), 1e-3)
    assert_in_delta(0.15,  GasMoney::Units.convert(0.241, from: :us_customary, to: :metric,      kind: :cost_per_distance), 1e-3)
  end

  test "round-trips return the original value" do
    cases = [
      { kind: :volume,           value: 50.0 },
      { kind: :distance,         value: 1234.5 },
      { kind: :economy,          value: 9.0 },
      { kind: :price_per_volume, value: 174.9 },
    ]
    cases.each do |c|
      there = GasMoney::Units.convert(c[:value], from: :metric, to: :us_customary, kind: c[:kind])
      back  = GasMoney::Units.convert(there,     from: :us_customary, to: :metric, kind: c[:kind])

      assert_in_delta(c[:value], back, 1e-6, "round-trip failed for #{c[:kind]}")
    end
  end

  test "convert raises for unknown systems" do
    assert_raises(ArgumentError) { GasMoney::Units.convert(1.0, from: :bogus, to: :metric, kind: :volume) }
    assert_raises(ArgumentError) { GasMoney::Units.convert(1.0, from: :metric, to: :bogus, kind: :volume) }
  end

  test "convert raises for unknown kinds" do
    assert_raises(ArgumentError) do
      GasMoney::Units.convert(1.0, from: :metric, to: :us_customary, kind: :temperature)
    end
  end

  test "label returns the expected human string per kind+system" do
    assert_equal("L",       GasMoney::Units.label(:volume,           :metric))
    assert_equal("gal",     GasMoney::Units.label(:volume,           :us_customary))
    assert_equal("km",      GasMoney::Units.label(:distance,         :metric))
    assert_equal("mi",      GasMoney::Units.label(:distance,         :us_customary))
    assert_equal("L/100km", GasMoney::Units.label(:economy,          :metric))
    assert_equal("MPG",     GasMoney::Units.label(:economy,          :us_customary))
    assert_equal("/L",      GasMoney::Units.label(:price_per_volume, :metric))
    assert_equal("/gal",    GasMoney::Units.label(:price_per_volume, :us_customary))
  end

  test "label raises for unknown system or kind" do
    assert_raises(ArgumentError) { GasMoney::Units.label(:volume, :imperial) }
    assert_raises(ArgumentError) { GasMoney::Units.label(:mass, :metric) }
  end
end

class MoneyTest < ActiveSupport::TestCase
  test "symbol returns the disambiguating label" do
    assert_equal("CA$", GasMoney::Money.symbol("CAD"))
    assert_equal("US$", GasMoney::Money.symbol("USD"))
  end

  test "symbol raises on unknown currency" do
    assert_raises(ArgumentError) { GasMoney::Money.symbol("EUR") }
    assert_raises(ArgumentError) { GasMoney::Money.symbol(nil) }
  end

  test "validate! raises only on unknown currency" do
    GasMoney::Money::CURRENCIES.each { |c| assert_nil(GasMoney::Money.validate!(c)) }
    assert_raises(ArgumentError) { GasMoney::Money.validate!("GBP") }
  end
end
