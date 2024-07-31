#  frozen_string_literal: true

require_relative "../model"

class Cert < Sequel::Model
  one_to_one :strand, key: :id

  include ResourceMethods
  include SemaphoreMethods
  semaphore :destroy

  plugin :column_encryption do |enc|
    enc.column :cert
    enc.column :private_key
    enc.column :csr_key
    enc.column :kid
  end
end
