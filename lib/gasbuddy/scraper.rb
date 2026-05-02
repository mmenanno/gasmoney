# frozen_string_literal: true

require "nokogiri"

module GasMoney
  module GasBuddy
    # Pure parsing functions for GasBuddy responses. Kept separate from
    # the HTTP client so they can be unit-tested with fixtures and don't
    # need network access.
    module Scraper
      VEHICLE_LINK_PATTERN = %r{\A/account/vehicles/(?<uuid>[0-9a-f-]{36})\z}

      ListEntry = Struct.new(:uuid, :filled_at, keyword_init: true)
      DetailEntry = Struct.new(
        :uuid,
        :filled_at,
        :total_cost,
        :quantity_liters,
        :unit_price_cents,
        :odometer,
        :l_per_100km,
        keyword_init: true,
      )

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

      # Parses the GraphQL response for the fuel-log-book entries list.
      # The exact GraphQL operation name and shape were inferred from
      # network traces; if the API shape changes, only this function
      # needs updating.
      def parse_fuel_log_list(graphql_response)
        rows = dig_collection(graphql_response, "data", "vehicleFuelLogs") ||
          dig_collection(graphql_response, "data", "fuelLogs") ||
          []
        rows.filter_map do |entry|
          uuid = entry["id"] || entry["uuid"]
          filled_at = entry["filledAt"] || entry["timestamp"] || entry["date"]
          next if uuid.nil? || filled_at.nil?

          ListEntry.new(uuid: uuid, filled_at: normalize_iso8601(filled_at))
        end
      end

      def parse_fuel_log_detail(graphql_response)
        entry = graphql_response.dig("data", "vehicleFuelLog") ||
          graphql_response.dig("data", "fuelLog")
        return if entry.nil?

        DetailEntry.new(
          uuid:             entry["id"] || entry["uuid"],
          filled_at:        normalize_iso8601(entry["filledAt"] || entry["timestamp"] || entry["date"]),
          total_cost:       to_float(entry["totalCost"] || entry["cost"]),
          quantity_liters:  to_float(entry["quantity"] || entry["liters"]),
          unit_price_cents: extract_unit_price_cents(entry),
          odometer:         to_int(entry["odometer"]),
          l_per_100km:      extract_economy(entry),
        )
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

      def dig_collection(payload, *keys)
        value = payload.dig(*keys)
        return value if value.is_a?(Array)

        nested = value.is_a?(Hash) ? value["entries"] || value["nodes"] || value["items"] : nil
        nested.is_a?(Array) ? nested : nil
      end

      # GasBuddy's GraphQL surfaces unit price in different shapes
      # depending on the operation. Accept either a flat cents value
      # ("unitPriceCents") or the more common dollar string ("price"
      # or "unitPrice") and normalise to cents.
      def extract_unit_price_cents(entry)
        cents = entry["unitPriceCents"]
        return to_float(cents) if cents

        dollars = entry["unitPrice"] || entry["price"]
        dollars_f = to_float(dollars)
        dollars_f && (dollars_f * 100.0).round(3)
      end

      def extract_economy(entry)
        # Fuel economy is typically L/100km on Canadian accounts. Accept
        # the value as-is; partial fills come through as nil/missing.
        to_float(entry["fuelEconomy"] || entry["economyLper100km"] || entry["lPer100km"])
      end
    end
  end
end
