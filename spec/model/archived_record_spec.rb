# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe ArchivedRecord do
  it "can be created" do
    expect { described_class.create(model_name: "Vm", model_values: {"state" => "creating"}) }.not_to raise_error
  end

  it "needs new partitions (action required)" do
    # if this test starts to fail, it's time to create new partitions for table archived_record. if this is ignored,
    # ArchivedRecord.create will start to fail in 45 days or less. it's also a good time to see if old partitions can be dropped.
    expect { described_class.create(archived_at: Time.now + 60 * 60 * 24 * 45, model_name: "Vm", model_values: {"state" => "creating"}) }.not_to raise_error
  end

  it "fails to create in the past" do
    expect { described_class.create(archived_at: Date.new(2024, 1, 1), model_name: "Vm", model_values: {"state" => "creating"}) }.to raise_error(Sequel::ConstraintViolation)
  end

  it "fails to create in the distant future" do
    expect { described_class.create(archived_at: Time.now + 60 * 60 * 24 * 365 * 10, model_name: "Vm", model_values: {"state" => "creating"}) }.to raise_error(Sequel::ConstraintViolation)
  end
end
