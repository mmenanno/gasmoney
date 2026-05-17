# frozen_string_literal: true

require "active_record"

module GasMoney
  class SavedTrip < ActiveRecord::Base
    self.record_timestamps = false

    UNIT_SYSTEMS = ["metric", "us_customary"].freeze

    validates :name, presence: true
    validates :base_distance, presence: true, numericality: { greater_than_or_equal_to: 0 }
    validates :unit_system, presence: true, inclusion: { in: UNIT_SYSTEMS }
  end
end
