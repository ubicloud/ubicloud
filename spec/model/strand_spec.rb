# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Strand do
  let(:st) {
    described_class.new(id: described_class.generate_uuid,
      prog: "Test",
      label: "start")
  }

  context "when leasing" do
    it "can take a lease only if one is not already taken" do
      st.save_changes
      did_it = st.take_lease_and_reload {
        expect(st.take_lease_and_reload {
                 :never_happens
               }).to be false

        :did_it
      }
      expect(did_it).to be :did_it
    end

    it "does an integrity check that deleted records are gone" do
      st.label = "hop_exit"
      st.save_changes
      original = DB.method(:[])
      expect(DB).to receive(:[]) do |*args, **kwargs|
        case args
        when ["SELECT FROM strand WHERE id = ?", st.id]
          instance_double(Sequel::Dataset, empty?: false)
        else
          original.call(*args, **kwargs)
        end
      end.at_least(:once)

      expect { st.run }.to raise_error RuntimeError, "BUG: strand with @deleted set still exists in the database"
    end

    it "does an integrity check that the lease was modified as expected" do
      st.label = "napper"
      st.save_changes
      original = DB.method(:[])
      expect(DB).to receive(:[]) do |*args, **kwargs|
        case args[0]
        when <<SQL
UPDATE strand
SET lease = NULL
WHERE id = ? AND lease = ?
SQL
          instance_double(Sequel::Dataset, update: 0)
        else
          original.call(*args, **kwargs)
        end
      end.at_least(:once)

      expect(Clog).to receive(:emit).with("lease violated data").and_call_original
      expect(Clog).to receive(:emit).at_least(:once).and_call_original
      expect { st.run }.to raise_error RuntimeError, "BUG: lease violated"
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
      st.unsynchronized_run
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
