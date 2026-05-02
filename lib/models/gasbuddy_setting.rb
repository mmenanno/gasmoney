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

    validates :flaresolverr_url, format: { with: %r{\Ahttps?://[^\s]+\z} }, allow_blank: true

    def self.current
      first || create!
    end

    def credentials_present?
      username.to_s.strip.present? && password.to_s.strip.present?
    end

    def flaresolverr_endpoint
      url = flaresolverr_url.to_s.strip
      return if url.empty?

      env_url = ENV["FLARESOLVERR_URL"].to_s.strip
      url == env_url ? env_url : url
    end

    # Effective FlareSolverr URL — DB value takes precedence over the env
    # var. Both must be valid http(s) URLs; otherwise return nil so the
    # sync code can short-circuit with a clear error.
    def self.effective_flaresolverr_url
      from_db = current.flaresolverr_url.to_s.strip
      from_env = ENV["FLARESOLVERR_URL"].to_s.strip
      url = from_db.empty? ? from_env : from_db
      url.match?(%r{\Ahttps?://[^\s]+\z}) ? url : nil
    end
  end
end
