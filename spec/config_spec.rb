# frozen_string_literal: true

RSpec.describe Config do
  it "can have float config" do
    described_class.class_eval %(
      override :test_float, 0.5, float
      ), __FILE__, __LINE__ - 2

    expect(described_class.test_float).to eq(0.5)
  end

  it "can have nil array config" do
    described_class.class_eval %(
      override :test_array, nil, array
      ), __FILE__, __LINE__ - 2

    expect(described_class.test_array).to be_nil
  end
end
