# frozen_string_literal: true

require "date"

require_relative "units"

module GasMoney
  module Calculator
    METHODS = ["exact", "between", "after_latest", "before_earliest"].freeze

    PerKm = Struct.new(
      :latest,
      :average5,
      :latest_filled_at,
      :sample_size,
      :unit_system,
      :currency,
      keyword_init: true,
    )

    class InsufficientData < StandardError; end

    # Math runs in the picked fillup's native units + currency; the
    # resulting trip_search is persisted back in the trip-input system
    # with the fillup's currency (no FX).
    def self.estimate(vehicle_id:, trip_date:, distance:, unit_system: :metric)
      vehicle = Vehicle.find(vehicle_id)
      trip_date = Date.parse(trip_date) if trip_date.is_a?(String)
      distance = Float(distance)
      trip_system = unit_system.to_sym

      inputs = pick_inputs(vehicle, trip_date)
      raise InsufficientData, "no fillups for vehicle" unless inputs[:unit_price_cents]

      fillup_system = inputs[:unit_system].to_sym
      distance_in_fillup = Units.convert(distance, from: trip_system, to: fillup_system, kind: :distance)
      fuel_used_in_fillup = fuel_used(fillup_system, inputs[:fuel_economy], distance_in_fillup)
      estimated_cost = (fuel_used_in_fillup * (inputs[:unit_price_cents] / 100.0)).round(2)

      TripSearch.create!(
        vehicle: vehicle,
        trip_date: trip_date.iso8601,
        distance: distance,
        estimated_cost: estimated_cost,
        fuel_used: convert(fuel_used_in_fillup, fillup_system, trip_system, :volume).round(3),
        unit_price_cents: convert(inputs[:unit_price_cents], fillup_system, trip_system, :price_per_volume).round(2),
        fuel_economy: convert(inputs[:fuel_economy], fillup_system, trip_system, :economy).round(2),
        calc_method: inputs[:calc_method],
        unit_system: trip_system.to_s,
        currency: inputs[:currency],
      )
    end

    # Never averages across mismatched (unit_system, currency) tuples —
    # falls back to the calendar-newer fillup instead.
    def self.pick_inputs(vehicle, trip_date)
      exact = vehicle.fillups.for_date(trip_date).recent_first.first
      return result(exact.unit_price_cents, exact.fuel_economy, "exact", exact) if exact&.fuel_economy

      before = vehicle.fillups.with_economy.before_date(trip_date).recent_first.first
      after  = vehicle.fillups.with_economy.after_date(trip_date).oldest_first.first

      if before && after
        return between_result(before, after) if same_tuple?(before, after)

        return result(after.unit_price_cents, after.fuel_economy, "before_earliest", after)
      end

      return result(after.unit_price_cents,  after.fuel_economy,  "before_earliest", after) if after
      return result(before.unit_price_cents, before.fuel_economy, "after_latest",    before) if before

      empty_result
    end

    def self.cost_per_distance_summary(vehicle)
      rows = vehicle.fillups.with_economy.recent_first.limit(5).to_a
      return empty_summary if rows.empty?

      anchor = rows.first
      same_group = rows.select { |r| same_tuple?(r, anchor) }
      ratios = same_group.filter_map(&:cost_per_distance)

      PerKm.new(
        latest:           ratios.first&.round(4),
        average5:         ratios.any? ? (ratios.sum / ratios.length).round(4) : nil,
        latest_filled_at: anchor.filled_at,
        sample_size:      ratios.length,
        unit_system:      anchor.unit_system,
        currency:         anchor.currency,
      )
    end

    def self.latest_fillup(vehicle)
      vehicle.fillups.recent_first.first
    end

    def self.fuel_used(fillup_system, fuel_economy, distance_in_fillup_units)
      case fillup_system
      when :metric        then (fuel_economy * distance_in_fillup_units) / 100.0
      when :us_customary  then distance_in_fillup_units / fuel_economy
      end
    end

    def self.convert(value, from, to, kind)
      Units.convert(value, from: from, to: to, kind: kind)
    end

    def self.same_tuple?(left, right)
      left.unit_system == right.unit_system && left.currency == right.currency
    end

    def self.result(unit_price_cents, fuel_economy, calc_method, fillup)
      {
        unit_price_cents: unit_price_cents,
        fuel_economy: fuel_economy,
        calc_method: calc_method,
        unit_system: fillup.unit_system,
        currency: fillup.currency,
      }
    end

    def self.between_result(before, after)
      avg_unit = (before.unit_price_cents + after.unit_price_cents) / 2.0
      avg_econ = (before.fuel_economy + after.fuel_economy) / 2.0
      {
        unit_price_cents: avg_unit,
        fuel_economy: avg_econ,
        calc_method: "between",
        unit_system: before.unit_system,
        currency: before.currency,
      }
    end

    def self.empty_result
      { unit_price_cents: nil, fuel_economy: nil, calc_method: nil, unit_system: nil, currency: nil }
    end

    def self.empty_summary
      PerKm.new(
        latest:           nil,
        average5:         nil,
        latest_filled_at: nil,
        sample_size:      0,
        unit_system:      nil,
        currency:         nil,
      )
    end
  end
end
