# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Strand do
  let(:st) { described_class.new(schedule: Time.now, prog: "Test", label: "start") }

  it "can take leases" do
    st.save_changes
    did_it = st.lease {
      next Prog::Test.new st.id
    }
    expect(did_it).to be true
  end

  it "can load a prog" do
    expect(st.load).to be_instance_of Prog::Test
  end

  it "can run a label" do
    st.save_changes
    sh = instance_spy(Prog::Test)
    expect(st).to receive(:load).and_return sh
    st.run
    expect(sh).to have_received(:start)
  end
end
