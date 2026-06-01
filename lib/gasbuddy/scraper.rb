# frozen_string_literal: true

require "nokogiri"

module GasMoney
  module GasBuddy
    # Pure parsing functions for GasBuddy responses. Kept separate from
    # the HTTP client so they can be unit-tested with fixtures and don't
    # need network access.
    module Scraper
      VEHICLE_LINK_PATTERN = %r{\A/account/vehicles/(?<uuid>[0-9a-f-]{36})\z}

      DetailEntry = Struct.new(
        :uuid,
        :filled_at,
        :total_cost,
        :quantity,
        :unit_price_cents,
        :odometer,
        :fuel_economy,
        :unit_system,
        :currency,
        keyword_init: true,
      )

      # GasBuddy returns the fuel-economy unit on every fillup; the
      # volume/odometer/currency fields don't carry per-field units in
      # the response we currently request, so we derive unit_system
      # from this signal and infer currency from unit_system.
      def self.unit_system_from_economy_units(units)
        case units.to_s.strip
        when "L/100km", "km/L" then "metric"
        when "MPG"             then "us_customary"
        end
      end

      def self.currency_for_unit_system(unit_system)
        unit_system == "us_customary" ? "USD" : "CAD"
      end

      extend self

      # Extracts (uuid, display_name) tuples from the /account/vehicles
      # HTML. Vehicles render as <a href="/account/vehicles/<uuid>"> with
      # the display name in the anchor's text. Robust against image-only
      # cards by also reading the link's text content.
      def parse_vehicles(html)
        doc = Nokogiri::HTML(html.to_s)
        anchors = doc.css('a[href^="/account/vehicles/"]')
        by_uuid = anchors.each_with_object({}) do |anchor, acc|
          href = anchor["href"].to_s.split("?").first
          match = VEHICLE_LINK_PATTERN.match(href)
          next unless match

          name = anchor.text.strip
          name = anchor.css("img").first&.[]("alt")&.sub(/^Vehicle photo of\s+/i, "") if name.empty?
          next if name.to_s.strip.empty?

          uuid = match[:uuid]
          # Multiple anchors may point at the same vehicle (image + text);
          # keep the longest name we see for each uuid.
          existing = acc[uuid]
          acc[uuid] = name if existing.nil? || existing.length < name.length
        end
        by_uuid.map { |uuid, name| { uuid: uuid, name: name } }
      end

      # Parses the GraphQL response for the root `fuelLogs(vehicleGuid:)`
      # query. Each FuelLog carries every field we need, so the
      # response is flattened into DetailEntry rows directly — no
      # separate detail fetch.
      def parse_fuel_logs(graphql_response)
        results = graphql_response.dig("data", "fuelLogs", "results")
        return [] unless results.is_a?(Array)

        results.filter_map do |entry|
          uuid = entry["guid"]
          purchase_date = entry["purchaseDate"]
          next if uuid.nil? || purchase_date.nil?

          fe_units = entry.dig("fuelEconomy", "fuelEconomy", "fuelEconomyUnits")
          unit_system = unit_system_from_economy_units(fe_units) || "metric"

          DetailEntry.new(
            uuid:             uuid,
            filled_at:        normalize_iso8601(purchase_date),
            total_cost:       to_float(entry["totalCost"]),
            quantity:         to_float(entry["amountFilled"]),
            unit_price_cents: to_float(entry["pricePerUnit"]),
            odometer:         to_int(entry["odometer"]),
            fuel_economy:     extract_economy(entry["fuelEconomy"]),
            unit_system:      unit_system,
            currency:         currency_for_unit_system(unit_system),
          )
        end
      end

      def normalize_iso8601(value)
        return if value.to_s.empty?

        Time.parse(value.to_s).utc.iso8601
      rescue ArgumentError
        value.to_s
      end

      def to_float(value)
        return if value.nil? || value.to_s.empty?

        Float(value)
      rescue ArgumentError, TypeError
        nil
      end

      def to_int(value)
        return if value.nil? || value.to_s.empty?

        Integer(value.to_s.split(".").first)
      rescue ArgumentError, TypeError
        nil
      end

      # GasBuddy nests the actual L/100km figure under
      # `fuelEconomy.fuelEconomy.fuelEconomy` (yes, three deep — that's
      # the shape `myVehicle.fuelLogs.results[].fuelEconomy` returns).
      # The outer `status` is "complete" for normal fillups and
      # "missingPrevious" for the first fillup of a tank or any fillup
      # without enough history to compute economy — those legitimately
      # have no L/100km and we surface that as nil.
      def extract_economy(fuel_economy)
        return if fuel_economy.nil?
        return if fuel_economy["status"] == "missingPrevious"

        to_float(fuel_economy.dig("fuelEconomy", "fuelEconomy"))
      end
    end
  end
end
