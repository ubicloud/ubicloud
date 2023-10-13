# frozen_string_literal: true

require_relative "../../model"

class DnsZone < Sequel::Model
  many_to_one :project
  many_to_many :dns_servers
  one_to_many :records, class: :DnsRecord
  one_to_one :active_billing_record, class: :BillingRecord, key: :resource_id do |ds| ds.active end

  include ResourceMethods
  include Authorization::HyperTagMethods
  include Authorization::TaggableMethods

  def hyper_tag_name(project)
    "project/#{project.ubid}/dns-zone/#{ubid}"
  end

  def insert_record(record_name:, type:, ttl:, data:)
    record_name = add_dot_if_missing(record_name)
    DnsRecord.create_with_id(dns_zone_id: id, name: record_name, type: type, ttl: ttl, data: data)
  rescue Sequel::UniqueConstraintViolation => ex
    raise unless ex.message.include?("duplicate key value violates unique constraint")
  end

  def delete_record(record_name:, type: nil, data: nil)
    fail "Type needs to be specified if data is specified!" if data && type.nil?

    record_name = add_dot_if_missing(record_name)
    records = records_dataset.where(name: record_name)
    records = records.where(type: type) if type
    records = records.where(data: data) if data
    records.update(tombstoned: true)
  end

  def add_dot_if_missing(record_name)
    (record_name[-1] == ".") ? record_name : record_name + "."
  end
end
