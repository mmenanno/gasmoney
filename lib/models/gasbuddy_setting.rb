# frozen_string_literal: true

require "active_record"

module GasMoney
  # Single-row settings record for the GasBuddy auto-sync integration.
  # `username`/`password`/`cookies_json` are encrypted at rest via
  # ActiveRecord::Encryption; the master keys are configured in
  # `GasMoney::Encryption.configure!` at boot.
  class GasbuddySetting < ActiveRecord::Base
    self.record_timestamps = false

    encrypts :username
    encrypts :password
    encrypts :cookies_json

    def self.current
      first || create!
    end

    def credentials_present?
      username.to_s.strip.present? && password.to_s.strip.present?
    end
  end
end
