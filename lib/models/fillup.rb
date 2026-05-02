# frozen_string_literal: true

require "active_record"

module GasMoney
  class Fillup < ActiveRecord::Base
    self.record_timestamps = false

    belongs_to :vehicle

    scope :with_economy,  -> { where.not(l_per_100km: nil) }
    scope :recent_first,  -> { order(filled_at: :desc) }
    scope :oldest_first,  -> { order(filled_at: :asc) }
    scope :for_date,      ->(date) { where("DATE(filled_at) = DATE(?)", iso(date)) }
    scope :before_date,   ->(date) { where("DATE(filled_at) < DATE(?)", iso(date)) }
    scope :after_date,    ->(date) { where("DATE(filled_at) > DATE(?)", iso(date)) }

    def self.iso(date)
      date.respond_to?(:iso8601) ? date.iso8601 : date.to_s
    end

    def cost_per_km
      return unless l_per_100km && unit_price_cents

      (l_per_100km / 100.0) * (unit_price_cents / 100.0)
    end
  end
end
