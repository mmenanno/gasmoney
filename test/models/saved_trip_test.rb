# frozen_string_literal: true

require "test_helper"

class SavedTripTest < ActiveSupport::TestCase
  test "requires a name" do
    assert_raises(ActiveRecord::RecordInvalid) do
      GasMoney::SavedTrip.create!(name: "", base_kilometers: 50)
    end
  end

  test "requires base_kilometers" do
    assert_raises(ActiveRecord::RecordInvalid) do
      GasMoney::SavedTrip.create!(name: "Commute", base_kilometers: nil)
    end
  end

  test "rejects negative base_kilometers" do
    assert_raises(ActiveRecord::RecordInvalid) do
      GasMoney::SavedTrip.create!(name: "Commute", base_kilometers: -5)
    end
  end

  test "round_trip defaults to off" do
    trip = GasMoney::SavedTrip.create!(name: "Commute", base_kilometers: 25)

    assert_equal(0, trip.round_trip)
  end
end
