# frozen_string_literal: true

require "active_record"

module GasMoney
  class TripSearch < ActiveRecord::Base
    self.record_timestamps = false

    UNIT_SYSTEMS = ["metric", "us_customary"].freeze
    CURRENCIES   = ["CAD", "USD"].freeze

    belongs_to :vehicle

    validates :unit_system, presence: true, inclusion: { in: UNIT_SYSTEMS }
    validates :currency,    presence: true, inclusion: { in: CURRENCIES }
  end
end
