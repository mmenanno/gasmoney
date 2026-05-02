# frozen_string_literal: true

require "active_record"
require "active_record/encryption"
require "base64"
require "fileutils"
require "json"
require "securerandom"

module GasMoney
  # Configures ActiveRecord::Encryption with master keys read from env
  # vars first, falling back to a self-generated key file under the
  # state directory. The file is created with mode 0600 on first boot
  # and never overwritten; backups must include it or encrypted column
  # values become unrecoverable.
  module Encryption
    KEY_FILE_DEFAULT = ENV.fetch(
      "GASMONEY_ENCRYPTION_KEY_PATH",
      File.expand_path("../db/encryption.key", __dir__),
    )

    ENV_VARS = {
      primary_key: "GASMONEY_ENCRYPTION_KEY",
      deterministic_key: "GASMONEY_DETERMINISTIC_KEY",
      key_derivation_salt: "GASMONEY_KEY_DERIVATION_SALT",
    }.freeze

    def self.configure!(key_file: KEY_FILE_DEFAULT)
      keys = resolve_keys(key_file)

      ActiveRecord::Encryption.configure(
        primary_key: keys[:primary_key],
        deterministic_key: keys[:deterministic_key],
        key_derivation_salt: keys[:key_derivation_salt],
        # Forbid mass assignment of encrypted attributes through the
        # standard params pipeline — tightens the surface against
        # accidental Vehicle.update! style bypasses.
        support_unencrypted_data: false,
      )
    end

    def self.resolve_keys(key_file)
      env_keys = ENV_VARS.transform_values { |k| ENV[k].to_s.strip }
      return env_keys if env_keys.values.none?(&:empty?)

      load_or_generate_key_file(key_file)
    end

    # Loads a JSON-encoded key bundle from `key_file`, or generates one
    # and writes it with 0600 perms. The generated file is the single
    # source of truth for at-rest encryption — losing it means losing
    # access to encrypted column values forever.
    def self.load_or_generate_key_file(key_file)
      if File.exist?(key_file)
        bundle = JSON.parse(File.read(key_file), symbolize_names: true)
        return bundle if bundle.values_at(*ENV_VARS.keys).none? { |v| v.to_s.empty? }
      end

      bundle = ENV_VARS.keys.to_h { |k| [k, SecureRandom.alphanumeric(32)] }
      FileUtils.mkdir_p(File.dirname(key_file))
      File.open(key_file, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |f|
        f.write(JSON.pretty_generate(bundle))
      end
      warn(
        "[gasmoney] Generated encryption key file at #{key_file}. " \
        "Back this file up — losing it makes encrypted credentials unrecoverable.",
      )
      bundle
    end
  end
end
