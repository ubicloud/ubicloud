# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Strand do
  let(:st) { described_class.new(prog: "Test", label: "start") }

  it "can take leases" do
    st.save_changes
    prog = Prog::Test.new st.id
    did_it = st.lease {
      next prog
    }
    expect(did_it).to be prog
  end

  it "can load a prog" do
    expect(st.load).to be_instance_of Prog::Test
  end

  it "can hop" do
    st.save_changes
    st.label = "hop_entry"
    expect(st).to receive(:load).and_return Prog::Test.new(st)
    expect {
      st.run
    }.to change(st, :label).from("hop_entry").to("hop_exit")
  end
end
