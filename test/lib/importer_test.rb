# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "stringio"

class ImporterTest < ActiveSupport::TestCase
  HEADER = '"Date (UTC)","Location","Station Link","Address","City","State","Country","Total Cost",' \
           '"Currency","Fuel Type","Quantity","Unit","Vehicle","Unit Price","Odometer","Fuel Economy",' \
           '"Fuel Economy Unit","Fillup","Notes"'

  setup do
    @vehicle = create_vehicle
  end

  test "raises if no vehicle is supplied" do
    assert_raises(ArgumentError) do
      GasMoney::Importer.import(StringIO.new(HEADER), vehicle: nil)
    end
  end

  test "imports a single row and assigns it to the supplied vehicle" do
    csv = <<~CSV
      #{HEADER}
      "2026-04-17 16:00:04","Pump A","","100 Test Rd","Anytown","XX","XX","105.45","CAD","regular_gas","64.733","liters","Anything","162.9",111616,"10.3","L/100km","Yes",
    CSV

    result = GasMoney::Importer.import(StringIO.new(csv), vehicle: @vehicle)

    assert_equal(1, result.inserted)
    assert_equal(0, result.duplicates)
    fillup = GasMoney::Fillup.first

    assert_equal(@vehicle.id, fillup.vehicle_id)
    assert_equal("2026-04-17T16:00:04Z", fillup.filled_at)
    assert_in_delta(10.3,    fillup.l_per_100km,      0.001)
    assert_in_delta(162.9,   fillup.unit_price_cents, 0.001)
    assert_in_delta(64.733,  fillup.quantity_liters,  0.001)
    assert_equal(0, fillup.partial_fill)
  end

  test "ignores the CSV's Vehicle column entirely" do
    # Even with a wildly wrong "Vehicle" value, the row should land under
    # the Vehicle the operator picked at import time.
    csv = <<~CSV
      #{HEADER}
      "2026-04-17 16:00:04","Pump A","","","","","","100","CAD","regular","50","liters","Some Other Car","160","100000","8","L/100km","Yes",
    CSV

    GasMoney::Importer.import(StringIO.new(csv), vehicle: @vehicle)

    assert_equal(@vehicle.id, GasMoney::Fillup.first.vehicle_id)
  end

  test "treats missingPrevious fuel economy as a partial fill with nil l_per_100km" do
    csv = <<~CSV
      #{HEADER}
      "2026-04-04 18:57:39","Pump A","","","","","","52.99","CAD","regular_gas","29.955","liters","X","176.9",110988,"missingPrevious","","Yes",
    CSV

    GasMoney::Importer.import(StringIO.new(csv), vehicle: @vehicle)
    fillup = GasMoney::Fillup.first

    assert_nil(fillup.l_per_100km)
    assert_equal(1, fillup.partial_fill)
  end

  test "dedups on (vehicle_id, filled_at, odometer, quantity_liters)" do
    row = <<~ROW
      "2026-04-17 16:00:04","Pump A","","","","","","105.45","CAD","regular_gas","64.733","liters","X","162.9",111616,"10.3","L/100km","Yes",
    ROW
    csv = "#{HEADER}\n#{row}"

    GasMoney::Importer.import(StringIO.new(csv), vehicle: @vehicle)
    second = GasMoney::Importer.import(StringIO.new(csv), vehicle: @vehicle)

    assert_equal(0, second.inserted)
    assert_equal(1, second.duplicates)
    assert_equal(1, GasMoney::Fillup.count)
  end

  test "appended row imports without re-inserting existing rows" do
    initial = <<~CSV
      #{HEADER}
      "2026-04-17 16:00:04","Pump A","","","","","","105.45","CAD","regular_gas","64.733","liters","X","162.9",111616,"10.3","L/100km","Yes",
    CSV
    new_row = '"2026-05-01 12:00:00","Pump A","","","","","","90.00","CAD","regular_gas","55.000","liters","X","163.6",112000,"9.5","L/100km","Yes",'
    augmented = "#{initial}#{new_row}\n"

    GasMoney::Importer.import(StringIO.new(initial), vehicle: @vehicle)
    second = GasMoney::Importer.import(StringIO.new(augmented), vehicle: @vehicle)

    assert_equal(1, second.inserted)
    assert_equal(1, second.duplicates)
    assert_equal(2, GasMoney::Fillup.count)
  end

  test "skips rows with malformed numeric fields without aborting the import" do
    csv = <<~CSV
      #{HEADER}
      "not-a-date","","","","","","","not-a-number","CAD","regular","50","liters","X","160","100000","8","L/100km","Yes",
      "2026-04-17 16:00:04","","","","","","","100","CAD","regular","50","liters","X","160","100001","8","L/100km","Yes",
    CSV

    result = GasMoney::Importer.import(StringIO.new(csv), vehicle: @vehicle)

    assert_equal(1, result.inserted)
    assert_equal(1, result.skipped)
  end

  test "accepts a path string in addition to an IO" do
    csv_path = File.join(Dir.tmpdir, "gasmoney_test_#{Process.pid}_#{rand(1_000_000)}.csv")
    File.write(csv_path, "#{HEADER}\n\"2026-04-17 16:00:04\",\"\",\"\",\"\",\"\",\"\",\"\",\"100\",\"CAD\",\"r\",\"50\",\"liters\",\"X\",\"160\",\"1000\",\"8\",\"L/100km\",\"Yes\",\n")
    begin
      result = GasMoney::Importer.import(csv_path, vehicle: @vehicle)

      assert_equal(1, result.inserted)
    ensure
      FileUtils.rm_f(csv_path)
    end
  end
end
