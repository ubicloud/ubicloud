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

  it "#inspect_values_hash includes set_at" do
    sem = described_class.create(name: "foo", strand_id: st.id)
    expect(Time.parse(sem.inspect_values_hash[:set_at] + " UTC")).to be_within(2).of(Time.now)
  end

  describe ".relay" do
    let(:st2) { Strand.create(prog: "Test", label: "start") }
    let(:st3) { Strand.create(prog: "Test", label: "start") }

    it "copies semaphore rows to target strands and deletes originals" do
      req1 = SecureRandom.uuid
      req2 = SecureRandom.uuid
      described_class.incr(st.id, "foo", req1)
      described_class.incr(st.id, "foo", req2)

      described_class.relay(st.id, :foo, [st2.id, st3.id], :bar)

      expect(described_class.where(strand_id: st.id, name: "foo").count).to eq 0
      expect(described_class.where(strand_id: st2.id, name: "bar").select_map(:request_id).sort).to eq [req1, req2].sort
      expect(described_class.where(strand_id: st3.id, name: "bar").select_map(:request_id).sort).to eq [req1, req2].sort
    end

    it "defaults to_name to name" do
      described_class.incr(st.id, "foo")
      described_class.relay(st.id, :foo, [st2.id])
      expect(described_class.where(strand_id: st2.id, name: "foo").count).to eq 1
    end
  end
end
