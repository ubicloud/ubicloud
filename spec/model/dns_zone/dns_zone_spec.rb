# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe DnsZone do
  subject(:dns_zone) {
    described_class.create(
      project_id: "00000000-0000-0000-0000-000000000000",
      name: "example.com"
    )
  }

  context "when inserting new record" do
    it "creates record in database" do
      dns_zone.insert_record(record_name: "test", type: "A", ttl: 10, data: "1.2.3.4")

      expect(dns_zone.records.count).to eq(1)
    end
  end

  context "when deleting a record" do
    before do
      DnsRecord.create(dns_zone_id: dns_zone.id, name: "test1.", type: "A", ttl: 10, data: "1.2.3.4")
      DnsRecord.create(dns_zone_id: dns_zone.id, name: "test1.", type: "A", ttl: 10, data: "5.6.7.8")
      DnsRecord.create(dns_zone_id: dns_zone.id, name: "test1.", type: "TXT", ttl: 10, data: "5.6.7.8")
      DnsRecord.create(dns_zone_id: dns_zone.id, name: "test2.", type: "A", ttl: 10, data: "5.6.7.8")
    end

    it "raises error if data is passed but type is not" do
      expect {
        dns_zone.delete_record(record_name: "test1", data: "1.2.3.4")
      }.to raise_error RuntimeError, "Type needs to be specified if data is specified!"
    end

    it "deletes all matching records from database when only record_name is passed" do
      dns_zone.delete_record(record_name: "test1")
      expect(dns_zone.records_dataset.where(:tombstoned).count).to eq(3)
    end

    it "does not insert new tombstoned records for existing tombstoned records" do
      4.times do
        dns_zone.delete_record(record_name: "test1")
      end
      expect(dns_zone.records_dataset.where(:tombstoned).count).to eq(12)
    end

    it "deletes all matching records from database when record_name and type are passed" do
      dns_zone.delete_record(record_name: "test1", type: "A")
      expect(dns_zone.records_dataset.where(:tombstoned).count).to eq(2)
    end

    it "deletes all matching records from database when record_name, type and data are passed" do
      dns_zone.delete_record(record_name: "test1", type: "A", data: "1.2.3.4")
      expect(dns_zone.records_dataset.where(:tombstoned).count).to eq(1)
    end
  end

  it "returns record_name with dot" do
    expect(dns_zone.add_dot_if_missing("pg-name.postgres.ubicloud.com")).to eq("pg-name.postgres.ubicloud.com.")
    expect(dns_zone.add_dot_if_missing("pg-name.postgres.ubicloud.com.")).to eq("pg-name.postgres.ubicloud.com.")
  end
end
