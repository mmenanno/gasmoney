# frozen_string_literal: true

require "rufus-scheduler"

module GasMoney
  # In-process scheduler for the daily auto-sync. Single-mode Puma means
  # exactly one instance runs per process; we guard with a class-level
  # singleton so re-loads (e.g. dev reloader, tests) don't stack timers.
  module Scheduler
    DAILY_CRON = "0 0 * * *" # midnight UTC

    @scheduler = nil
    @mutex = Mutex.new

    def self.start!(logger: nil)
      @mutex.synchronize do
        return @scheduler if @scheduler

        scheduler = Rufus::Scheduler.new
        scheduler.cron(DAILY_CRON) do
          run_scheduled_sync(logger)
        end
        @scheduler = scheduler
      end
    end

    def self.shutdown!
      @mutex.synchronize do
        @scheduler&.shutdown(:wait)
        @scheduler = nil
      end
    end

    def self.run_now_async(trigger:, logger: nil)
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          GasBuddy::Sync.run(trigger: trigger, logger: logger)
        end
      rescue StandardError => e
        logger&.error("[scheduler] sync thread crashed: #{e.message}")
      end
    end

    def self.run_scheduled_sync(logger)
      ActiveRecord::Base.connection_pool.with_connection do
        setting = GasbuddySetting.current
        return unless setting.auto_sync_enabled
        return unless setting.credentials_present?
        return unless GasbuddySetting.effective_flaresolverr_url

        GasBuddy::Sync.run(trigger: "scheduled", logger: logger)
      end
    rescue StandardError => e
      logger&.error("[scheduler] daily sync failed: #{e.message}")
    end
  end
end
