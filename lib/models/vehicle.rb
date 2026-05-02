# frozen_string_literal: true

require "active_record"

module GasMoney
  class Vehicle < ActiveRecord::Base
    self.record_timestamps = false

    has_many :fillups,       dependent: :destroy
    has_many :trip_searches, dependent: :destroy

    validates :display_name, presence: true, length: { maximum: 80 }

    scope :pinned,       -> { where(pinned: true) }
    scope :ordered,      -> { order(:display_name) }
    scope :pinned_first, -> { order(pinned: :desc, display_name: :asc) }

    def pinned? = pinned
  end
end
