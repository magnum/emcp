# frozen_string_literal: true

# Development and production keep different Active Record encryption keys.
# db:remote_pull copies ciphertext written with the production key, so
# development also accepts that key for reading. New local writes stay on
# the development key.
if Rails.env.development?
  key_path = Rails.root.join("config/credentials/production.key")
  content_path = Rails.root.join("config/credentials/production.yml.enc")

  if key_path.file? && content_path.file?
    keys = Rails.application.encrypted(content_path, key_path: key_path).dig(:active_record_encryption) || {}
    current = Rails.application.credentials.dig(:active_record_encryption) || {}
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
