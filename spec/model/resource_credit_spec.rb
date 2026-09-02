# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe ResourceCredit do
  let(:project) { Project.create(name: "p1") }

  def create(attrs)
    described_class.create({
      project_id: project.id,
      name: "Test credit",
      amount: 10,
      active_from: Time.utc(2026, 1, 1),
    }.merge(attrs))
  end

  describe "check constraints" do
    it "rejects resource_id without resource_type" do
      expect { create(resource_id: project.id) }.to raise_error(Sequel::ValidationFailed)
      expect {
        DB[:resource_credit].insert(
          id: UBID.generate(UBID::TYPE_RESOURCE_CREDIT).to_uuid,
          project_id: project.id, resource_id: project.id, name: "x",
          amount: 10, active_from: Time.utc(2026, 1, 1),
        )
      }.to raise_error(Sequel::CheckConstraintViolation, /resource_id_requires_type/)
    end

    it "allows resource_id when resource_type is set" do
      expect { create(resource_id: project.id, resource_type: "VmVCpu") }.not_to raise_error
    end

    it "rejects amount below 0" do
      expect { create(amount: -1) }.to raise_error(Sequel::ValidationFailed)
    end

    it "allows amount of 0" do
      expect { create(amount: 0) }.not_to raise_error
    end

    it "rejects active_to <= active_from" do
      expect {
        create(active_from: Time.utc(2026, 2, 1), active_to: Time.utc(2026, 1, 1))
      }.to raise_error(Sequel::ValidationFailed)
    end

    it "rejects active_from that is not the start of a UTC month" do
      expect {
        create(active_from: Time.utc(2026, 1, 15))
      }.to raise_error(Sequel::ValidationFailed)
    end

    it "rejects active_to that is not the start of a UTC month" do
      expect {
        create(active_from: Time.utc(2026, 1, 1), active_to: Time.utc(2026, 2, 15))
      }.to raise_error(Sequel::ValidationFailed)
    end

    it "rejects non-month-aligned values at the database level when validations are bypassed" do
      expect {
        DB[:resource_credit].insert(
          id: UBID.generate(UBID::TYPE_RESOURCE_CREDIT).to_uuid,
          project_id: project.id, name: "x",
          amount: 10, active_from: Time.utc(2026, 1, 15),
        )
      }.to raise_error(Sequel::CheckConstraintViolation, /month_aligned/)
    end

    it "accepts UTC month-start active_from with NULL active_to" do
      expect { create(active_from: Time.utc(2026, 1, 1)) }.not_to raise_error
    end

    it "allows multiple overlapping wildcard credits for the same project" do
      create({})
      expect { create({}) }.not_to raise_error
    end
  end

  describe "#matches?" do
    it "matches when all non-null columns equal the line item's values" do
      rc = described_class.new(resource_type: "VmVCpu", resource_family: "standard", location: "hetzner-fsn1")
      expect(rc.matches?(resource_id: "abc", resource_type: "VmVCpu", resource_family: "standard", location: "hetzner-fsn1", byoc: false)).to be(true)
    end

    it "does not match when a non-null column disagrees" do
      rc = described_class.new(resource_type: "VmVCpu")
      expect(rc.matches?(resource_id: "abc", resource_type: "PostgresVCpu", resource_family: "standard", location: "hetzner-fsn1", byoc: false)).to be(false)
    end

    it "treats NULL columns as wildcards" do
      rc = described_class.new
      expect(rc.matches?(resource_id: "abc", resource_type: "VmVCpu", resource_family: "standard", location: "hetzner-fsn1", byoc: false)).to be(true)
    end
  end

  describe "#wildcard?" do
    it "is true when no matcher column is set" do
      expect(described_class.new.wildcard?).to be(true)
    end

    it "is false when any matcher column is set" do
      expect(described_class.new(resource_type: "VmVCpu").wildcard?).to be(false)
      expect(described_class.new(byoc: false).wildcard?).to be(false)
    end
  end
end
