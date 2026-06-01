# frozen_string_literal: true

require "test_helper"

class VehicleTest < ActiveSupport::TestCase
  test "requires a display_name" do
    assert_raises(ActiveRecord::RecordInvalid) do
      GasMoney::Vehicle.create!(display_name: "")
    end
  end

  test "rejects display_name longer than 80 chars" do
    assert_raises(ActiveRecord::RecordInvalid) do
      GasMoney::Vehicle.create!(display_name: "x" * 81)
    end
  end

  test "defaults to unpinned" do
    v = create_vehicle

    refute_predicate(v, :pinned?)
  end

  test "pinned scope returns only pinned vehicles" do
    pinned = create_vehicle(display_name: "Pinned Wagon", pinned: true)
    create_vehicle(display_name: "Unpinned Hatchback", pinned: false)

    assert_equal([pinned], GasMoney::Vehicle.pinned.to_a)
  end

  test "ordered scope sorts by display_name ascending" do
    create_vehicle(display_name: "Zebra")
    create_vehicle(display_name: "Apple")
    create_vehicle(display_name: "Mango")

    assert_equal(["Apple", "Mango", "Zebra"], GasMoney::Vehicle.ordered.pluck(:display_name))
  end

  test "pinned_first scope sorts pinned vehicles ahead of unpinned" do
    create_vehicle(display_name: "B Unpinned", pinned: false)
    create_vehicle(display_name: "A Unpinned", pinned: false)
    create_vehicle(display_name: "B Pinned",   pinned: true)
    create_vehicle(display_name: "A Pinned",   pinned: true)

    assert_equal(
      ["A Pinned", "B Pinned", "A Unpinned", "B Unpinned"],
      GasMoney::Vehicle.pinned_first.pluck(:display_name),
    )
  end

  test "destroying a vehicle cascades to fillups" do
    v = create_vehicle
    create_fillup(vehicle: v)

    assert_difference("GasMoney::Fillup.count", -1) do
      v.destroy!
    end
  end

  test "destroying a vehicle cascades to trip searches" do
    v = create_vehicle
    create_fillup(vehicle: v)
    GasMoney::Calculator.estimate(
      vehicle_id: v.id,
      trip_date:  "2026-02-15",
      distance:   100,
    )

    assert_difference("GasMoney::TripSearch.count", -1) do
      v.destroy!
    end
  end
end
