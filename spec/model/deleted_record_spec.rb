# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe DeletedRecord do
  def partition_days
    described_class.partition_days
  end

  it "can be created" do
    expect { described_class.create(model_name: "Vm", model_values: {"state" => "creating"}) }.not_to raise_error
  end

  it "fails to create outside the retained partitions" do
    expect { described_class.create(deleted_at: Time.now - (60 * 60 * 24 * 90), model_name: "Vm", model_values: {}) }
      .to raise_error(Sequel::ConstraintViolation)
    expect { described_class.create(deleted_at: Time.now + (60 * 60 * 24 * 90), model_name: "Vm", model_values: {}) }
      .to raise_error(Sequel::ConstraintViolation)
  end

  describe ".find_by_id" do
    it "finds a record by id within the given number of days" do
      id = Vm.generate_uuid
      described_class.create(model_name: "Vm", record_id: id, model_values: {"id" => id, "name" => "vm1"})

      expect(described_class.find_by_id(id, model_name: "Vm")[:model_values]["name"]).to eq "vm1"
      expect(described_class.find_by_id(id, model_name: "Sshable")).to be_nil
      expect(described_class.find_by_id(Vm.generate_uuid, model_name: "Vm")).to be_nil
    end

    it "does not find records outside the window" do
      described_class.create_partition(Time.now.utc.to_date - 3)
      described_class.create(deleted_at: Time.now - (60 * 60 * 24 * 3), model_name: "Vm", record_id: (id = Vm.generate_uuid), model_values: {})
      expect(described_class.find_by_id(id, model_name: "Vm", days: 5)).not_to be_nil
      expect(described_class.find_by_id(id, model_name: "Vm", days: 1)).to be_nil
    end
  end

  describe ".vms_by_ips" do
    it "joins deleted addresses to deleted vms through the indexed record_id" do
      vm_id = Vm.generate_uuid
      described_class.create(model_name: "Vm", record_id: vm_id,
        model_values: {"id" => vm_id, "name" => "deleted-vm", "created_at" => Time.now.to_s, "boot_image" => "ubuntu-jammy", "project_id" => Project.generate_uuid})
      described_class.create(model_name: "AssignedVmAddress", record_id: AssignedVmAddress.generate_uuid,
        model_values: {"ip" => "1.2.3.4/32", "dst_vm_id" => vm_id})

      rows = described_class.vms_by_ips(["1.2.3.4/32"])
      expect(rows.length).to eq 1
      expect(rows[0][:vm_name]).to eq "deleted-vm"
      expect(rows[0][:vm_id]).to eq vm_id
      expect(rows[0][:ip]).to eq "1.2.3.4/32"
      expect(rows[0][:deleted_at]).to be_within(5).of(Time.now)

      expect(described_class.vms_by_ips(["5.6.7.8/32"])).to be_empty
      expect(described_class.vms_by_ips(["1.2.3.4/32"], days: 0)).to be_empty
    end
  end

  describe "partition maintenance" do
    it "names partitions after the UTC day they hold" do
      expect(described_class.partition_name(Date.new(2026, 5, 14))).to eq "deleted_record_2026_05_14"
    end

    it "lists the days that have partitions" do
      today = Time.now.utc.to_date
      expect(partition_days).to include(today)
      expect(partition_days).to eq partition_days.sort
    end

    it "creates a partition that routes rows for its day, with the parent's indexes" do
      day = Time.now.utc.to_date + 90
      expect(partition_days).not_to include(day)
      described_class.create_partition(day)
      expect(partition_days).to include(day)

      described_class.create(deleted_at: Time.utc(day.year, day.month, day.day, 12), model_name: "Vm", model_values: {})
      expect(DB[:"deleted_record_#{day.strftime("%Y_%m_%d")}"].count).to eq 1

      name = described_class.partition_name(day)
      indexes = DB[Sequel[:pg_index]]
        .join(Sequel[:pg_class].as(:c), oid: :indexrelid)
        .where(indrelid: Sequel.cast(name, :regclass), indisvalid: true)
        .select_map(Sequel[:c][:relname])
      expect(indexes).to contain_exactly("#{name}_model_name_deleted_at_idx", "#{name}_record_id_idx", "#{name}_deleted_at_idx")
    end

    it "drops a partition" do
      day = Time.now.utc.to_date + 91
      described_class.create_partition(day)
      described_class.drop_partition(day)
      expect(partition_days).not_to include(day)
    end

    it "reports no runway at all when the table has no partitions" do
      partition_days.each { described_class.drop_partition(it) }
      expect(described_class.partition_runway_days).to be_nil
    end

    it "reports contiguous runway from today, and -1 when today has no partition" do
      today = Time.now.utc.to_date
      described_class.ensure_partitions(through: today + 3)
      expect(described_class.partition_runway_days).to eq(partition_days.max - today)

      described_class.drop_partition(today + 1)
      expect(described_class.partition_runway_days).to eq 0

      described_class.drop_partition(today)
      expect(described_class.partition_runway_days).to eq(-1)
    end

    it "creates only the missing partitions through the given day" do
      today = Time.now.utc.to_date
      described_class.ensure_partitions(through: today + 3)
      described_class.drop_partition(today + 2)
      described_class.drop_partition(today + 3)

      expect(described_class.ensure_partitions(through: today + 3)).to eq [today + 2, today + 3]
      expect(described_class.ensure_partitions(through: today + 3)).to be_empty
      expect(described_class.partition_runway_days).to be >= 3
    end
  end
end
