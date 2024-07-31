#  frozen_string_literal: true

require_relative "../model"

class Cert < Sequel::Model
  one_to_one :strand, key: :id

  include ResourceMethods
  include SemaphoreMethods
  semaphore :destroy

  plugin :column_encryption do |enc|
    enc.column :account_key
    enc.column :csr_key
  end

  def self.redacted_columns
    super + [:cert]
  end
end
