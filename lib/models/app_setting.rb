# frozen_string_literal: true

require "active_record"

module GasMoney
  class AppSetting < ActiveRecord::Base
    self.record_timestamps = false

    UNIT_SYSTEMS = ["metric", "us_customary"].freeze
    CURRENCY_LABEL_VISIBILITIES = ["auto", "always", "never"].freeze

    validates :display_unit_system,
      presence: true,
      inclusion: { in: UNIT_SYSTEMS }
    validates :currency_label_visibility,
      presence: true,
      inclusion: { in: CURRENCY_LABEL_VISIBILITIES }

    def self.current
      first || create!
    end

    def display_unit_system_sym = display_unit_system.to_sym
  end
end
