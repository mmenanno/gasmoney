# frozen_string_literal: true

require "active_record"

module GasMoney
  class SyncRun < ActiveRecord::Base
    self.record_timestamps = false

    has_many :sync_log_entries, -> { order(:created_at, :id) }, dependent: :destroy

    STATUSES = ["running", "ok", "failed", "partial"].freeze
    TRIGGERS = ["scheduled", "manual"].freeze

    validates :status, inclusion: { in: STATUSES }
    validates :trigger, inclusion: { in: TRIGGERS }

    scope :recent, -> { order(started_at: :desc) }

    def running? = status == "running"
    def ok? = status == "ok"
    def failed? = status == "failed"
    def partial? = status == "partial"

    def duration_seconds
      return if finished_at.nil? || started_at.nil?

      (Time.parse(finished_at) - Time.parse(started_at)).round
    rescue ArgumentError
      nil
    end

    def log!(level, message, detail: nil)
      sync_log_entries.create!(level: level, message: message, detail: detail&.to_json)
    end
  end
end
