# frozen_string_literal: true

require "active_record"

require_relative "../units"

module GasMoney
  # `quantity` / `fuel_economy` / `unit_price_cents` / `total_cost` are
  # interpreted under each row's `unit_system` and `currency` tags:
  #
  #   metric:        litres, L/100km, ¢/L
  #   us_customary:  US gallons, MPG, ¢/gal
  #   currency:      'CAD' or 'USD' (no FX conversion)
  class Fillup < ActiveRecord::Base
    self.record_timestamps = false

    UNIT_SYSTEMS = ["metric", "us_customary"].freeze
    CURRENCIES   = ["CAD", "USD"].freeze

    belongs_to :vehicle

    validates :unit_system, presence: true, inclusion: { in: UNIT_SYSTEMS }
    validates :currency,    presence: true, inclusion: { in: CURRENCIES }

    scope :with_economy,  -> { where.not(fuel_economy: nil) }
    scope :recent_first,  -> { order(filled_at: :desc) }
    scope :oldest_first,  -> { order(filled_at: :asc) }
    scope :for_date,      ->(date) { where("DATE(filled_at) = DATE(?)", iso(date)) }
    scope :before_date,   ->(date) { where("DATE(filled_at) < DATE(?)", iso(date)) }
    scope :after_date,    ->(date) { where("DATE(filled_at) > DATE(?)", iso(date)) }

    def self.iso(date)
      date.respond_to?(:iso8601) ? date.iso8601 : date.to_s
    end

    def self.distinct_currency_count
      distinct.pluck(:currency).size
    end

    EQUIVALENCE_TOLERANCE_LITERS = 0.5

    def self.find_equivalent(vehicle_id:, filled_at:, odometer:, quantity:, unit_system:, currency:)
      return if quantity.nil? || currency.nil?

      base = where(vehicle_id: vehicle_id, filled_at: filled_at, currency: currency)
      base = odometer.nil? ? base.where(odometer: nil) : base.where(odometer: odometer)

      with_quantity_match(base, quantity, unit_system).first
    end

    # No odometer match — GasBuddy's odometer values drift from manual
    # entries often enough that requiring exact match loses legitimate
    # links.
    def self.find_linkable_remote(vehicle_id:, filled_at:, quantity:, unit_system:, currency:, window_hours: 36)
      return if quantity.nil? || currency.nil? || filled_at.nil?

      target = Time.parse(filled_at)
      window_start = (target - (window_hours * 3_600)).iso8601
      window_end   = (target + (window_hours * 3_600)).iso8601

      base = where(vehicle_id: vehicle_id, gasbuddy_entry_uuid: nil, currency: currency)
        .where(filled_at: window_start..window_end)

      with_quantity_match(base, quantity, unit_system).first
    rescue ArgumentError
      nil
    end

    def self.with_quantity_match(scope, quantity, unit_system)
      qty_metric =
        if unit_system == "us_customary"
          Units.convert(quantity.to_f, from: :us_customary, to: :metric, kind: :volume)
        else
          quantity.to_f
        end
      metric_lo = qty_metric - EQUIVALENCE_TOLERANCE_LITERS
      metric_hi = qty_metric + EQUIVALENCE_TOLERANCE_LITERS
      us_lo = Units.convert(metric_lo, from: :metric, to: :us_customary, kind: :volume)
      us_hi = Units.convert(metric_hi, from: :metric, to: :us_customary, kind: :volume)

      scope.where(
        "(unit_system = 'metric' AND quantity BETWEEN ? AND ?) OR " \
        "(unit_system = 'us_customary' AND quantity BETWEEN ? AND ?)",
        metric_lo,
        metric_hi,
        us_lo,
        us_hi,
      )
    end

    # metric:        (L/100km × $/L) → $/km
    # us_customary:  $/gal ÷ MPG    → $/mi
    def cost_per_distance
      return unless fuel_economy && unit_price_cents
      return if fuel_economy.zero?

      case unit_system
      when "metric"
        (fuel_economy / 100.0) * (unit_price_cents / 100.0)
      when "us_customary"
        (unit_price_cents / 100.0) / fuel_economy
      end
    end
  end
end
