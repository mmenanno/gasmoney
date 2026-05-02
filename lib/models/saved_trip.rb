# frozen_string_literal: true

require "active_record"

module GasMoney
  class SavedTrip < ActiveRecord::Base
    self.record_timestamps = false

    validates :name, presence: true
    validates :base_kilometers, presence: true, numericality: { greater_than_or_equal_to: 0 }
  end
end
