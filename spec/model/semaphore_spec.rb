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

  it ".set_at returns the Time the given semaphore id was set at" do
    expect(described_class.set_at(described_class.generate_uuid)).to be_within(1).of(Time.now)
  end

  it "#set_at returns the Time the semaphore was set at" do
    sem = described_class.create(name: "foo", strand_id: st.id)
    expect(sem.set_at).to be_within(1).of(Time.now)
  end
end
