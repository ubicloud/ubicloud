# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe ResourceDiscount do
  let(:project) { Project.create(name: "p1") }
  let(:other_project) { Project.create(name: "p2") }

  def create(attrs)
    described_class.create({
      project_id: project.id,
      discount_percent: 10,
      active_from: Time.utc(2026, 1, 1),
    }.merge(attrs))
  end

  describe "check constraints" do
    it "rejects resource_id without resource_type" do
      expect { create(resource_id: project.id) }.to raise_error(Sequel::ValidationFailed)
      expect {
        DB[:resource_discount].insert(
          id: UBID.generate(UBID::TYPE_RESOURCE_DISCOUNT).to_uuid,
          project_id: project.id, resource_id: project.id,
          discount_percent: 10, active_from: Time.utc(2026, 1, 1),
        )
      }.to raise_error(Sequel::CheckConstraintViolation, /resource_id_requires_type/)
    end

    it "allows resource_id when resource_type is set" do
      expect { create(resource_id: project.id, resource_type: "VmVCpu") }.not_to raise_error
    end

    it "rejects discount_percent above 100" do
      expect { create(discount_percent: 101) }.to raise_error(Sequel::ValidationFailed)
    end

    it "rejects discount_percent below 0" do
      expect { create(discount_percent: -1) }.to raise_error(Sequel::ValidationFailed)
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

    it "rejects active_from that is the start of a day but not the start of a month" do
      expect {
        create(active_from: Time.utc(2026, 1, 2))
      }.to raise_error(Sequel::ValidationFailed)
    end

    it "rejects active_to that is not the start of a UTC month" do
      expect {
        create(active_from: Time.utc(2026, 1, 1), active_to: Time.utc(2026, 2, 15))
      }.to raise_error(Sequel::ValidationFailed)
    end

    it "rejects non-month-aligned values at the database level when validations are bypassed" do
      expect {
        DB[:resource_discount].insert(
          id: UBID.generate(UBID::TYPE_RESOURCE_DISCOUNT).to_uuid,
          project_id: project.id,
          discount_percent: 10, active_from: Time.utc(2026, 1, 15),
        )
      }.to raise_error(Sequel::CheckConstraintViolation, /month_aligned/)
    end

    it "accepts UTC month-start active_from with NULL active_to" do
      expect { create(active_from: Time.utc(2026, 1, 1)) }.not_to raise_error
    end
  end

  describe "overlap trigger" do
    it "allows same-pattern rules with disjoint time ranges" do
      create(resource_type: "VmVCpu", active_from: Time.utc(2026, 1, 1), active_to: Time.utc(2026, 2, 1))
      expect {
        create(resource_type: "VmVCpu", active_from: Time.utc(2026, 3, 1), active_to: Time.utc(2026, 4, 1))
      }.not_to raise_error
    end

    it "allows adjacent time ranges due to '[)' semantics" do
      create(resource_type: "VmVCpu", active_from: Time.utc(2026, 1, 1), active_to: Time.utc(2026, 2, 1))
      expect {
        create(resource_type: "VmVCpu", active_from: Time.utc(2026, 2, 1), active_to: Time.utc(2026, 3, 1))
      }.not_to raise_error
    end

    it "allows rules with non-overlapping concrete match values" do
      create(resource_type: "VmVCpu")
      expect { create(resource_type: "PostgresVCpu") }.not_to raise_error
    end

    it "allows rules on different projects even if they'd otherwise conflict" do
      create(resource_type: "VmVCpu")
      expect {
        described_class.create(
          project_id: other_project.id,
          discount_percent: 10,
          active_from: Time.utc(2026, 1, 1),
          resource_type: "VmVCpu",
        )
      }.not_to raise_error
    end

    it "rejects two wildcard rules for the same project" do
      create({})
      expect { create({}) }.to raise_error(Sequel::DatabaseError, /overlaps/)
    end

    it "rejects wildcard + concrete for the same project" do
      create({})
      expect { create(resource_type: "VmVCpu") }.to raise_error(Sequel::DatabaseError, /overlaps/)
    end

    it "rejects cross-column wildcards that share an intersecting match set" do
      create(resource_type: "PostgresVCpu")
      expect {
        create(resource_family: "standard-c6gd")
      }.to raise_error(Sequel::DatabaseError, /overlaps/)
    end

    it "rejects subset/superset rules" do
      create(resource_type: "PostgresVCpu")
      expect {
        create(resource_type: "PostgresVCpu", resource_family: "standard")
      }.to raise_error(Sequel::DatabaseError, /overlaps/)
    end

    it "allows rules with different byoc values" do
      create(resource_type: "VmVCpu", byoc: true)
      expect { create(resource_type: "VmVCpu", byoc: false) }.not_to raise_error
    end

    it "rejects byoc wildcard overlapping with concrete byoc" do
      create(resource_type: "VmVCpu")
      expect { create(resource_type: "VmVCpu", byoc: true) }.to raise_error(Sequel::DatabaseError, /overlaps/)
    end

    it "allows updates that keep the row non-overlapping with its siblings" do
      rd = create(resource_type: "VmVCpu", active_from: Time.utc(2026, 1, 1), active_to: Time.utc(2026, 2, 1))
      create(resource_type: "VmVCpu", active_from: Time.utc(2026, 3, 1), active_to: Time.utc(2026, 4, 1))

      expect { rd.update(discount_percent: 25) }.not_to raise_error
    end
  end

  describe "#matches?" do
    it "matches when all non-null columns equal the line item's values" do
      rd = described_class.new(resource_type: "VmVCpu", resource_family: "standard", location: "hetzner-fsn1")
      expect(rd.matches?(resource_id: "abc", resource_type: "VmVCpu", resource_family: "standard", location: "hetzner-fsn1", byoc: false)).to be(true)
    end

    it "does not match when a non-null column disagrees" do
      rd = described_class.new(resource_type: "VmVCpu")
      expect(rd.matches?(resource_id: "abc", resource_type: "PostgresVCpu", resource_family: "standard", location: "hetzner-fsn1", byoc: false)).to be(false)
    end

    it "treats NULL columns as wildcards" do
      rd = described_class.new
      expect(rd.matches?(resource_id: "abc", resource_type: "VmVCpu", resource_family: "standard", location: "hetzner-fsn1", byoc: false)).to be(true)
    end

    it "matches byoc when discount byoc is true and line item is byoc" do
      rd = described_class.new(byoc: true)
      expect(rd.matches?(resource_id: "abc", resource_type: "VmVCpu", resource_family: "standard", location: "hetzner-fsn1", byoc: true)).to be(true)
    end

    it "does not match when discount byoc disagrees with line item" do
      rd = described_class.new(byoc: true)
      expect(rd.matches?(resource_id: "abc", resource_type: "VmVCpu", resource_family: "standard", location: "hetzner-fsn1", byoc: false)).to be(false)
    end
  end
end
