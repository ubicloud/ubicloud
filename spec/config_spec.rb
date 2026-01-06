# frozen_string_literal: true

RSpec.describe Config do
  it "can have float config" do
    described_class.class_eval do
      override :test_float, 0.5, float
    end

    expect(described_class.test_float).to eq(0.5)
  end

  it "can have nil array config" do
    described_class.class_eval do
      override :test_array, nil, array
    end

    expect(described_class.test_array).to be_nil
  end

  it "uuid accepts valid uuid" do
    id = SecureRandom.uuid
    described_class.class_eval do
      override :test_valid_uuid, id, uuid
    end
    expect(described_class.test_valid_uuid).to eq(id)
  end

  it "uuid accepts nil" do
    described_class.class_eval do
      optional :test_nil_uuid, uuid
    end
    expect(described_class.test_nil_uuid).to be_nil
  end

  it "uuid rejects invalid uuid" do
    expect {
      described_class.class_eval do
        override :test_valid_uuid, "invalid", uuid
      end
    }.to raise_error("invalid uuid invalid")
  end
end
