# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Semaphore do
  let(:st) { Strand.create(prog: "Test", label: "start") }

  it ".incr returns nil and does not add Semaphore if there is no related strand" do
    expect(described_class.all).to be_empty
    expect(described_class.incr(Vm.generate_uuid, "foo")).to be_nil
    expect(described_class.all).to be_empty
  end

  it ".incr raises if invalid name is given" do
    expect { described_class.incr(st.id, nil) }.to raise_error(RuntimeError)
  end
end
