# frozen_string_literal: true

require "test_helper"

class GasbuddySettingTest < ActiveSupport::TestCase
  test "username and password are encrypted at rest" do
    setting = GasMoney::GasbuddySetting.current
    setting.update!(username: "halorrr", password: "supersecret")

    raw = ActiveRecord::Base.connection.exec_query(
      "SELECT username, password FROM gasbuddy_settings WHERE id = ?", "q", [setting.id]
    ).first

    refute_includes(raw["username"].to_s, "halorrr")
    refute_includes(raw["password"].to_s, "supersecret")
  end

  test "credentials_present? requires both fields" do
    setting = GasMoney::GasbuddySetting.current

    refute_predicate(setting, :credentials_present?)

    setting.update!(username: "u")

    refute_predicate(setting, :credentials_present?)

    setting.update!(password: "p")

    assert_predicate(setting, :credentials_present?)
  end

  test "effective_flaresolverr_url prefers DB value over env var" do
    GasMoney::GasbuddySetting.current.update!(flaresolverr_url: "http://from-db:8191")
    ENV["FLARESOLVERR_URL"] = "http://from-env:8191"

    assert_equal("http://from-db:8191", GasMoney::GasbuddySetting.effective_flaresolverr_url)
  ensure
    ENV.delete("FLARESOLVERR_URL")
  end

  test "effective_flaresolverr_url returns nil when neither source is set" do
    GasMoney::GasbuddySetting.current.update!(flaresolverr_url: nil)
    ENV.delete("FLARESOLVERR_URL")

    assert_nil(GasMoney::GasbuddySetting.effective_flaresolverr_url)
  end

  test "effective_flaresolverr_url rejects malformed values" do
    GasMoney::GasbuddySetting.current.update!(flaresolverr_url: nil)
    ENV["FLARESOLVERR_URL"] = "notaurl"

    assert_nil(GasMoney::GasbuddySetting.effective_flaresolverr_url)
  ensure
    ENV.delete("FLARESOLVERR_URL")
  end
end
