# frozen_string_literal: true

# config/credentials/development.yml.enc replaces the shared credentials
# file. It has no Active Record encryption keys; those stay in
# config/credentials.yml.enc. db:remote_pull also copies ciphertext written
# with the production key, so development accepts that key for reading.
# New local writes stay on the development key.
if Rails.env.development?
  current = Rails.application.credentials.dig(:active_record_encryption) || {}

  if current[:primary_key].blank? || current[:key_derivation_salt].blank?
    shared_path = Rails.root.join("config/credentials.yml.enc")
    shared_key = Rails.root.join("config/master.key")

    if shared_path.file? && shared_key.file?
      shared = Rails.application.encrypted(shared_path, key_path: shared_key).dig(:active_record_encryption) || {}

      if shared[:primary_key].present? && shared[:key_derivation_salt].present?
        ActiveRecord::Encryption.config.primary_key = shared[:primary_key]
        ActiveRecord::Encryption.config.deterministic_key = shared[:deterministic_key]
        ActiveRecord::Encryption.config.key_derivation_salt = shared[:key_derivation_salt]
        ActiveRecord::Encryption.reset_default_context
        current = shared
      end
    end
  end

  key_path = Rails.root.join("config/credentials/production.key")
  content_path = Rails.root.join("config/credentials/production.yml.enc")

  if key_path.file? && content_path.file?
    keys = Rails.application.encrypted(content_path, key_path: key_path).dig(:active_record_encryption) || {}
    primary = keys[:primary_key].presence
    salt = keys[:key_derivation_salt].presence

    if primary && salt && (primary != current[:primary_key] || salt != current[:key_derivation_salt])
      digest = ActiveRecord::Encryption.config.hash_digest_class
      secret = ActiveSupport::KeyGenerator.new(primary, hash_digest_class: digest)
        .generate_key(salt, ActiveRecord::Encryption.cipher.key_length)
      provider = ActiveRecord::Encryption::KeyProvider.new(ActiveRecord::Encryption::Key.new(secret))
      ActiveRecord::Encryption.config.previous = [ { key_provider: provider } ]
    end
  end
end
