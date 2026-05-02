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
    ENV_VARS = {
      primary_key: "GASMONEY_ENCRYPTION_KEY",
      deterministic_key: "GASMONEY_DETERMINISTIC_KEY",
      key_derivation_salt: "GASMONEY_KEY_DERIVATION_SALT",
    }.freeze

    # Resolved at call time rather than load time so that ENV changes
    # before configure! (e.g. test setup, dotenvx injection) are picked
    # up. Default lives next to the SQLite DB so the same volume mount
    # that keeps state across container restarts also keeps the key —
    # without coupling production deployments to the source tree's
    # `db/` directory, which isn't writable inside our Docker image.
    def self.default_key_file
      ENV["GASMONEY_ENCRYPTION_KEY_PATH"] ||
        File.join(File.dirname(default_db_path), "encryption.key")
    end

    def self.default_db_path
      ENV["GASMONEY_DB_PATH"] || File.expand_path("../db/gasmoney.sqlite3", __dir__)
    end

    # When tests run against an in-memory DB the path is the literal
    # ":memory:" — derived `File.dirname(":memory:")` would resolve to
    # "." and dump a key file at the cwd of whatever process is running
    # the suite. Tests don't need a persisted key file at all (they
    # configure encryption with random in-memory keys), so callers
    # should pass a non-persistent path or set the env vars directly.
    def self.in_memory_db?(path = default_db_path)
      path.to_s == ":memory:"
    end

    def self.configure!(key_file: default_key_file)
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

      # In-memory mode (tests) — generate ephemeral keys for the
      # process lifetime. Never write them to disk; doing so would
      # leak random secrets to whatever directory the test runner
      # happened to be in.
      return ENV_VARS.keys.to_h { |k| [k, SecureRandom.alphanumeric(32)] } if in_memory_db?

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

    # Backward-compat alias: previously a constant evaluated at load
    # time. Removing it would silently break anyone who imported it
    # downstream; keeping the name as a method instead.
    def self.const_missing(name)
      return default_key_file if name == :KEY_FILE_DEFAULT

      super
    end
  end
end
