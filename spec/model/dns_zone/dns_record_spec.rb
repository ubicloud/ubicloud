# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe DnsRecord do
  let(:dns_zone) { DnsZone.create(project_id:, name: "example.com") }
  let(:project_id) { Project.create(name: "test").id }

  describe "validate" do
    it "requires name in the zone" do
      dns_zone.insert_record(record_name: "test.example.com", type: "A", ttl: 10, data: "1.2.3.4")
      dns_zone.insert_record(record_name: "test.sub.example.com", type: "A", ttl: 10, data: "1.2.3.4")
      expect do
        dns_zone.insert_record(record_name: "test.bad-example.com", type: "A", ttl: 10, data: "1.2.3.4")
      end.to raise_error(Sequel::ValidationFailed)
    end
  end
end
