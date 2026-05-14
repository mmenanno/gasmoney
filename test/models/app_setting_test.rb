# frozen_string_literal: true

require "test_helper"

class AppSettingTest < ActiveSupport::TestCase
  test "current creates a row on first call with default values" do
    assert_equal(0, GasMoney::AppSetting.count)

    setting = GasMoney::AppSetting.current

    assert_predicate(setting, :persisted?)
    assert_equal("metric", setting.display_unit_system)
    assert_equal("auto",   setting.currency_label_visibility)
    assert_equal(1, GasMoney::AppSetting.count)
  end

  test "current returns the same row on subsequent calls" do
    first = GasMoney::AppSetting.current
    second = GasMoney::AppSetting.current

    assert_equal(first.id, second.id)
    assert_equal(1, GasMoney::AppSetting.count)
  end

  test "validates display_unit_system inclusion" do
    setting = GasMoney::AppSetting.new(display_unit_system: "imperial", currency_label_visibility: "auto")

    refute_predicate(setting, :valid?)
    assert_includes(setting.errors[:display_unit_system].join, "included")
  end

  test "validates currency_label_visibility inclusion" do
    setting = GasMoney::AppSetting.new(display_unit_system: "metric", currency_label_visibility: "sometimes")

    refute_predicate(setting, :valid?)
    assert_includes(setting.errors[:currency_label_visibility].join, "included")
  end

  test "display_unit_system_sym returns the symbol form" do
    setting = GasMoney::AppSetting.current

    assert_equal(:metric, setting.display_unit_system_sym)
    setting.update!(display_unit_system: "us_customary")

    assert_equal(:us_customary, setting.display_unit_system_sym)
  end

  test "update persists new values" do
    setting = GasMoney::AppSetting.current
    setting.update!(display_unit_system: "us_customary", currency_label_visibility: "always")

    reloaded = GasMoney::AppSetting.current

    assert_equal("us_customary", reloaded.display_unit_system)
    assert_equal("always",       reloaded.currency_label_visibility)
  end
end
