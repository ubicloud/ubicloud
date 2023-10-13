# frozen_string_literal: true

require_relative "../../model"

class DnsRecord < Sequel::Model
  include ResourceMethods
end
