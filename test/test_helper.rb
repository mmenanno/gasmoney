# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("..", __dir__))
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

ENV["RACK_ENV"] ||= "test"
ENV["GASMONEY_DB_PATH"] = ":memory:"

require "minitest/autorun"
require "minitest/reporters"
require "active_support"
require "active_support/test_case"
require "active_support/testing/time_helpers"

Minitest::Reporters.use!(Minitest::Reporters::ProgressReporter.new)

require "db"
GasMoney::DB.connect(":memory:")

module ActiveSupport
  class TestCase
    # Fork-based parallelism. Each worker gets its own :memory: SQLite,
    # which keeps row state, AR connections, and any module-level caches
    # naturally isolated. Threads would share the same heap and the
    # in-memory adapter doesn't model that cleanly.
    env_workers = ENV["MINITEST_WORKERS"].to_s.strip
    parallelize(
      workers: env_workers.empty? ? :number_of_processors : Integer(env_workers),
      with: :processes,
    )

    # Each worker re-establishes its own connection + schema after fork.
    # The inherited :memory: handle from the parent points at a database
    # the child can't see.
    parallelize_setup do |_worker|
      ActiveRecord::Base.connection_handler.clear_all_connections!
      GasMoney::DB.connect(":memory:")
    end

    parallelize_teardown do |_worker|
      ActiveRecord::Base.connection_handler.clear_all_connections!
    end

    include ActiveSupport::Testing::TimeHelpers

    # Each test runs in a transaction that's rolled back at teardown, so
    # rows created in one test don't leak into the next one running on
    # the same worker.
    setup do
      ActiveRecord::Base.connection.begin_transaction(joinable: false)
    end

    teardown do
      conn = ActiveRecord::Base.connection
      conn.rollback_transaction if conn.transaction_open?
    end

    private

    # Convenience factory used across tests. Defaults are deliberately
    # non-personal (generic body styles) so the suite reads as documentation
    # for new contributors rather than as a snapshot of the author's garage.
    def create_vehicle(display_name: "Test Sedan", pinned: false)
      GasMoney::Vehicle.create!(display_name: display_name, pinned: pinned)
    end

    def create_fillup(vehicle:, **attrs)
      defaults = {
        filled_at: "2026-01-15T12:00:00Z",
        total_cost: 50.00,
        quantity_liters: 40.0,
        unit_price_cents: 125.0,
        odometer: 50_000,
        l_per_100km: 9.0,
      }
      GasMoney::Fillup.create!(defaults.merge(attrs).merge(vehicle: vehicle))
    end
  end
end
