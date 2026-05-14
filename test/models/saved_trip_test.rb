# frozen_string_literal: true

require "test_helper"

class SavedTripTest < ActiveSupport::TestCase
  test "requires a name" do
    assert_raises(ActiveRecord::RecordInvalid) do
      GasMoney::SavedTrip.create!(name: "", base_distance: 50)
    end
  end

  test "requires base_distance" do
    assert_raises(ActiveRecord::RecordInvalid) do
      GasMoney::SavedTrip.create!(name: "Commute", base_distance: nil)
    end
  end

  test "rejects negative base_distance" do
    assert_raises(ActiveRecord::RecordInvalid) do
      GasMoney::SavedTrip.create!(name: "Commute", base_distance: -5)
    end
  end

  test "round_trip defaults to off" do
    trip = GasMoney::SavedTrip.create!(name: "Commute", base_distance: 25)

    assert_equal(0, trip.round_trip)
  end
end
