# frozen_string_literal: true

require_relative "../model"

class StorageKeyEncryptionKey < Sequel::Model
  plugin :column_encryption do |enc|
    enc.column :key
    enc.column :init_vector
  end

  include ResourceMethods

  def secret_key_material_hash
    # default to_hash doesn't decrypt encrypted columns, so implement
    # this to decrypt keys when they need to be sent to a running copy
    # of spdk.
    {
      "key" => key,
      "init_vector" => init_vector,
      "algorithm" => algorithm,
      "auth_data" => auth_data
    }
  end
end
