# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Strand do
  let(:st) { described_class.new(prog: "Test", label: "start") }

  context "when leasing" do
    it "can take a lease only if one is not already taken" do
      st.save_changes
      did_it = st.lease {
        expect(st.lease {
                 :never_happens
               }).to be false

        :did_it
      }
      expect(did_it).to be :did_it
    end

    it "deletes semaphores if the strand has exited" do
      st.exitval = {status: "exited"}
      st.save_changes
      Semaphore.incr(st.id, :bogus)

      expect {
        expect(st.lease { :never_happens }).to be_nil
      }.to change { Semaphore.where(strand_id: st.id).any? }.from(true).to(false)
    end
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

  it "rejects prog names that are not in the right module" do
    expect {
      described_class.prog_verify(Object)
    }.to raise_error RuntimeError, "BUG: prog must be in Prog module"
  end

  it "crashes if a label does not provide flow control" do
    expect {
      st.unsynchronized_run
    }.to raise_error RuntimeError, "BUG: Prog Test#start did not provide flow control"
  end

  it "can run labels consecutively if a deadline is not reached" do
    st.label = "hop_entry"
    st.save_changes
    expect {
      st.run(10)
    }.to change { [st.label, st.exitval] }.from(["hop_entry", nil]).to(["hop_exit", {msg: "hop finished"}])
  end
end
