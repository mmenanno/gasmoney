# frozen_string_literal: true

require "active_record"

module GasMoney
  class TripSearch < ActiveRecord::Base
    self.record_timestamps = false
    belongs_to :vehicle
  end
end
