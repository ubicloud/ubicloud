# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe ArchivedRecord do
  it "can be created" do
    expect { described_class.create(model_name: "Vm", model_values: {"state" => "creating"}) }.not_to raise_error
  end

  it "needs new partitions (action required)" do
    begin
      DB.transaction(savepoint: true) do
        described_class.create(archived_at: Time.now + 60 * 60 * 24 * 60, model_name: "Vm", model_values: {"state" => "creating"})
      end
    rescue Sequel::ConstraintViolation
      warn "\n\nNEED TO CREATE MORE archived_record PARTITIONS!\n\n\n"
    end

    expect { described_class.create(archived_at: Time.now + 60 * 60 * 24 * 45, model_name: "Vm", model_values: {"state" => "creating"}) }.not_to raise_error
  end

  it "fails to create in the past" do
    expect { described_class.create(archived_at: Date.new(2024, 1, 1), model_name: "Vm", model_values: {"state" => "creating"}) }.to raise_error(Sequel::ConstraintViolation)
  end

  it "fails to create in the distant future" do
    expect { described_class.create(archived_at: Time.now + 60 * 60 * 24 * 365 * 10, model_name: "Vm", model_values: {"state" => "creating"}) }.to raise_error(Sequel::ConstraintViolation)
  end

  # Destroys write to deleted_record now, so this table is only ever read.
  it "finds archived record by id" do
    id = Vm.generate_uuid
    described_class.create(model_name: "Vm", model_values: {"id" => id, "name" => "archived-vm"})
    record = described_class.find_by_id(id, model_name: "Vm")
    expect(record).not_to be_nil
    expect(record[:model_values]["id"]).to eq(id)
    expect(record[:model_values]["name"]).to eq("archived-vm")
    expect(record[:archived_at]).to be_within(5).of(Time.now)
    expect(described_class.find_by_id(id, model_name: "Sshable")).to be_nil
  end
end
