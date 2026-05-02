# frozen_string_literal: true

require "active_record"

module GasMoney
  class SyncLogEntry < ActiveRecord::Base
    self.record_timestamps = false

    belongs_to :sync_run

    LEVELS = ["info", "warn", "error"].freeze
    validates :level, inclusion: { in: LEVELS }

    def parsed_detail
      return if detail.to_s.empty?

      JSON.parse(detail)
    rescue JSON::ParserError
      nil
    end
  end
end
