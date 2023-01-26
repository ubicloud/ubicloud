# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Strand do
  it "can take leases" do
    st = described_class.create(schedule: Time.now, cprog: "invalid", label: "invalid")
    did_it = st.lease {}
    expect(did_it).to be true
  end
end
