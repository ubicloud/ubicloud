# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Strand do
  it "can take leases" do
    st = described_class.create(schedule: Time.now, cprog: "invalid", label: "invalid")
    did_it = st.lease {}
    expect(did_it).to be true
  end

  it "can load a cprog" do
    st = described_class.create(schedule: Time.now, cprog: "StartHypervisor", label: "start")
    expect(st.load).to be_instance_of CProg::StartHypervisor
  end
end
