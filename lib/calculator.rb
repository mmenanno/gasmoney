# frozen_string_literal: true

require "date"

module GasMoney
  module Calculator
    METHODS = ["exact", "between", "after_latest", "before_earliest"].freeze

    PerKm = Struct.new(:latest, :average5, :latest_filled_at, :sample_size, keyword_init: true)

    class InsufficientData < StandardError; end

    def self.estimate(vehicle_id:, trip_date:, kilometers:)
      vehicle = Vehicle.find(vehicle_id)
      trip_date = Date.parse(trip_date) if trip_date.is_a?(String)
      kilometers = Float(kilometers)

      unit_price_cents, l_per_100km, calc_method = pick_inputs(vehicle, trip_date)
      raise InsufficientData, "no fillups for vehicle" unless unit_price_cents

      liters_used = (l_per_100km * kilometers) / 100.0
      estimated_cost = (liters_used * (unit_price_cents / 100.0)).round(2)

      TripSearch.create!(
        vehicle: vehicle,
        trip_date: trip_date.iso8601,
        kilometers: kilometers,
        estimated_cost: estimated_cost,
        liters_used: liters_used.round(3),
        unit_price_cents: unit_price_cents.round(2),
        l_per_100km: l_per_100km.round(2),
        calc_method: calc_method,
      )
    end

    def self.pick_inputs(vehicle, trip_date)
      exact = vehicle.fillups.for_date(trip_date).recent_first.first
      return [exact.unit_price_cents, exact.l_per_100km, "exact"] if exact&.l_per_100km

      before = vehicle.fillups.with_economy.before_date(trip_date).recent_first.first
      after  = vehicle.fillups.with_economy.after_date(trip_date).oldest_first.first

      if before && after
        avg_unit = (before.unit_price_cents + after.unit_price_cents) / 2.0
        avg_econ = (before.l_per_100km + after.l_per_100km) / 2.0
        return [avg_unit, avg_econ, "between"]
      end

      return [after.unit_price_cents,  after.l_per_100km,  "before_earliest"] if after
      return [before.unit_price_cents, before.l_per_100km, "after_latest"]    if before

      [nil, nil, nil]
    end

    def self.cost_per_km_summary(vehicle)
      rows = vehicle.fillups.with_economy.recent_first.limit(5).to_a
      return PerKm.new(latest: nil, average5: nil, latest_filled_at: nil, sample_size: 0) if rows.empty?

      ratios = rows.map(&:cost_per_km)
      PerKm.new(
        latest:           ratios.first.round(4),
        average5:         (ratios.sum / ratios.length).round(4),
        latest_filled_at: rows.first.filled_at,
        sample_size:      rows.length,
      )
    end

    def self.latest_fillup(vehicle)
      vehicle.fillups.recent_first.first
    end
  end
end
