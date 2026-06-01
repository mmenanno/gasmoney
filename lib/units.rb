# frozen_string_literal: true

module GasMoney
  module Units
    SYSTEMS = [:metric, :us_customary].freeze

    LITERS_PER_GALLON   = 3.78541
    KILOMETERS_PER_MILE = 1.60934

    # x_L_per_100km * y_MPG ≈ 235.214583 — the two scales are reciprocal,
    # not linear, so the same formula converts in both directions.
    ECONOMY_RECIPROCAL_CONSTANT = 235.214583

    LABELS = {
      volume: { metric: "L", us_customary: "gal" },
      distance: { metric: "km", us_customary: "mi" },
      economy: { metric: "L/100km", us_customary: "MPG" },
      price_per_volume: { metric: "/L", us_customary: "/gal" },
      cost_per_distance: { metric: "/km", us_customary: "/mi" },
    }.freeze

    KINDS = LABELS.keys.freeze

    def self.convert(value, from:, to:, kind:)
      return if value.nil?

      validate_kind!(kind)
      validate_system!(from)
      validate_system!(to)

      v = value.to_f
      return v if from == to

      case kind
      when :volume
        from == :metric ? v / LITERS_PER_GALLON : v * LITERS_PER_GALLON
      when :distance
        from == :metric ? v / KILOMETERS_PER_MILE : v * KILOMETERS_PER_MILE
      when :economy
        # Zero economy yields Float::INFINITY; treat 0 as a bug upstream.
        ECONOMY_RECIPROCAL_CONSTANT / v
      when :price_per_volume
        from == :metric ? v * LITERS_PER_GALLON : v / LITERS_PER_GALLON
      when :cost_per_distance
        from == :metric ? v * KILOMETERS_PER_MILE : v / KILOMETERS_PER_MILE
      end
    end

    def self.label(kind, system)
      validate_kind!(kind)
      validate_system!(system)
      LABELS.fetch(kind).fetch(system)
    end

    def self.validate_system!(system)
      raise ArgumentError, "Unknown unit system: #{system.inspect}" unless SYSTEMS.include?(system)
    end

    def self.validate_kind!(kind)
      raise ArgumentError, "Unknown unit kind: #{kind.inspect}" unless KINDS.include?(kind)
    end
  end

  # No FX — fillups keep their native currency forever; the UI just
  # changes whether it disambiguates the symbol.
  module Money
    CURRENCIES = ["CAD", "USD"].freeze

    SYMBOLS = {
      "CAD" => "CA$",
      "USD" => "US$",
    }.freeze

    PLAIN_SYMBOL = "$"

    def self.symbol(currency)
      validate!(currency)
      SYMBOLS.fetch(currency)
    end

    def self.validate!(currency)
      raise ArgumentError, "Unknown currency: #{currency.inspect}" unless CURRENCIES.include?(currency)
    end
  end
end
