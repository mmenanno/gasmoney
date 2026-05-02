# frozen_string_literal: true

require "csv"
require "time"

module GasMoney
  module Importer
    Result = Struct.new(:inserted, :duplicates, :skipped, keyword_init: true) do
      def total = inserted + duplicates + skipped
    end

    DEDUP_KEYS = [:vehicle_id, :filled_at, :odometer, :quantity_liters].freeze

    # Imports a CSV against the supplied vehicle. The CSV's "Vehicle" column
    # is ignored — every row is attributed to `vehicle`. This decouples the
    # importer from GasBuddy's free-text vehicle naming.
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
      fillup = Fillup.find_or_initialize_by(attrs.slice(*DEDUP_KEYS))
      if fillup.persisted?
        result.duplicates += 1
      else
        fillup.assign_attributes(attrs)
        fillup.save!
        result.inserted += 1
      end
    rescue ArgumentError, TypeError, ActiveRecord::RecordInvalid
      result.skipped += 1
    end

    def self.build_attrs(row, vehicle_id)
      l_per_100km, partial_fill = parse_fuel_economy(row)
      {
        vehicle_id: vehicle_id,
        filled_at: Time.parse("#{row["Date (UTC)"]} UTC").utc.iso8601,
        total_cost: Float(row["Total Cost"]),
        quantity_liters: Float(row["Quantity"]),
        unit_price_cents: Float(row["Unit Price"]),
        odometer: parse_int(row["Odometer"]),
        l_per_100km: l_per_100km,
        partial_fill: partial_fill,
        fuel_type: row["Fuel Type"],
        location: presence(row["Location"]),
        city: presence(row["City"]),
        notes: presence(row["Notes"]),
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

    def self.parse_fuel_economy(row)
      raw = row["Fuel Economy"].to_s.strip
      return [nil, 1] if raw.empty? || raw == "missingPrevious"
      return [nil, 1] unless row["Fuel Economy Unit"].to_s.strip == "L/100km"

      [Float(raw), 0]
    end

    def self.parse_int(value)
      return if blank?(value)

      Integer(value.to_s.strip)
    rescue ArgumentError
      nil
    end

    def self.presence(value) = blank?(value) ? nil : value

    def self.blank?(value) = value.nil? || value.to_s.strip.empty?
  end
end
