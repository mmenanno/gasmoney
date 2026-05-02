# frozen_string_literal: true

require "active_record"

module GasMoney
  # Persisted GasBuddy garage. Each row mirrors a vehicle on the
  # user's GasBuddy account; the `ignored` flag lets the user mark
  # a remote vehicle as deliberately out-of-scope so the sync flow
  # stops nagging them to link it.
  class GasbuddyRemoteVehicle < ActiveRecord::Base
    self.record_timestamps = false

    validates :uuid, presence: true, uniqueness: true
    validates :display_name, presence: true

    scope :active,  -> { where(ignored: false) }
    scope :ignored, -> { where(ignored: true) }
    scope :ordered, -> { order(:display_name) }

    def linked_vehicle
      Vehicle.find_by(gasbuddy_uuid: uuid)
    end

    def linked? = !linked_vehicle.nil?
  end
end
