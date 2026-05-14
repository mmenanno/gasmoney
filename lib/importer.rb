# frozen_string_literal: true

require "csv"
require "time"

require_relative "units"

module GasMoney
  module Importer
    Result = Struct.new(:inserted, :duplicates, :skipped, keyword_init: true) do
      def total = inserted + duplicates + skipped
    end

    # Documentation of the identity tuple — the SQL unique index uses
    # these columns, but actual dedup goes through Fillup.find_equivalent
    # which normalises quantity across unit systems before matching.
    DEDUP_KEYS = [:vehicle_id, :filled_at, :odometer, :quantity, :unit_system, :currency].freeze

    METRIC_VOLUME_UNITS  = ["liters", "litres", "l"].freeze
    US_VOLUME_UNITS      = ["gallons", "gal", "gallon"].freeze
    METRIC_ECONOMY_UNITS = ["L/100km", "km/L"].freeze
    US_ECONOMY_UNITS     = ["MPG"].freeze
    SUPPORTED_CURRENCIES = ["CAD", "USD"].freeze
    DEFAULT_CURRENCY     = "CAD"

    # The CSV's "Vehicle" column is ignored — every row is attributed to
    # the supplied vehicle.
    def self.import(source, vehicle:)
      raise ArgumentError, "vehicle is required" if vehicle.nil?

      csv = open_csv(source)
      result = Result.new(inserted: 0, duplicates: 0, skipped: 0)

      ActiveRecord::Base.transaction do
        csv.each { |row| process_row(row, vehicle.id, result) }
      end

      result
    end

    def self.process_row(row, vehicle_id, result)
      attrs = build_attrs(row, vehicle_id)

      existing = Fillup.find_equivalent(
        vehicle_id:  vehicle_id,
        filled_at:   attrs[:filled_at],
        odometer:    attrs[:odometer],
        quantity:    attrs[:quantity],
        unit_system: attrs[:unit_system],
        currency:    attrs[:currency],
      )
      if existing
        result.duplicates += 1
      else
        Fillup.create!(attrs)
        result.inserted += 1
      end
    rescue ActiveRecord::RecordNotUnique
      result.duplicates += 1
    rescue ArgumentError, TypeError, ActiveRecord::RecordInvalid
      result.skipped += 1
    end

    def self.build_attrs(row, vehicle_id)
      unit_system = detect_unit_system(row)
      raise ArgumentError, "row has conflicting unit signals" unless unit_system

      currency = detect_currency(row)

      {
        vehicle_id: vehicle_id,
        filled_at: Time.parse("#{row["Date (UTC)"]} UTC").utc.iso8601,
        total_cost: Float(row["Total Cost"]),
        quantity: Float(row["Quantity"]),
        unit_price_cents: Float(row["Unit Price"]),
        odometer: parse_int(row["Odometer"]),
        fuel_economy: parse_fuel_economy(row),
        unit_system: unit_system,
        currency: currency,
      }
    end

    def self.open_csv(source)
      opts = { headers: true, skip_blanks: true }
      content =
        if source.respond_to?(:read)
          source.rewind if source.respond_to?(:rewind)
          source.read
        else
          File.read(source)
        end
      content = content.dup.force_encoding("UTF-8")
      content.delete_prefix!("﻿") # strip BOM if present
      CSV.parse(content, **opts)
    end

    # nil when the two signals disagree (e.g. `liters` + `MPG`); falls
    # back to metric when both are absent.
    def self.detect_unit_system(row)
      from_volume  = unit_system_from_volume_unit(row["Unit"])
      from_economy = unit_system_from_economy_unit(row["Fuel Economy Unit"])

      return if from_volume && from_economy && from_volume != from_economy

      from_volume || from_economy || "metric"
    end

    def self.unit_system_from_volume_unit(unit)
      return if unit.to_s.strip.empty?

      normalised = unit.to_s.strip.downcase
      return "metric" if METRIC_VOLUME_UNITS.include?(normalised)
      return "us_customary" if US_VOLUME_UNITS.include?(normalised)

      nil
    end

    def self.unit_system_from_economy_unit(unit)
      return if unit.to_s.strip.empty?

      raw = unit.to_s.strip
      return "metric" if METRIC_ECONOMY_UNITS.include?(raw)
      return "us_customary" if US_ECONOMY_UNITS.include?(raw)

      nil
    end

    def self.detect_currency(row)
      raw = row["Currency"].to_s.strip.upcase
      SUPPORTED_CURRENCIES.include?(raw) ? raw : DEFAULT_CURRENCY
    end

    # Nil for partial fills (`missingPrevious`) and unknown units —
    # `fuel_economy IS NULL` is the canonical partial-fill check.
    def self.parse_fuel_economy(row)
      raw = row["Fuel Economy"].to_s.strip
      return if raw.empty? || raw == "missingPrevious"

      unit = row["Fuel Economy Unit"].to_s.strip
      return unless METRIC_ECONOMY_UNITS.include?(unit) || US_ECONOMY_UNITS.include?(unit)

      Float(raw)
    end

    def self.parse_int(value)
      return if value.nil? || value.to_s.strip.empty?

      Integer(value.to_s.strip)
    rescue ArgumentError
      nil
    end
  end
end
