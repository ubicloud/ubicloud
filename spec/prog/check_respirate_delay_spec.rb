# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::CheckRespirateDelay do
  subject(:nx) { described_class.new(st) }

  let(:st) { Strand.create(prog: "CheckRespirateDelay", label: "wait") }

  def run_late(seconds)
    metrics = st.respirate_metrics
    metrics.lease_checked = metrics.scheduled + seconds
  end

  describe "#wait" do
    it "naps when run up to 20 seconds late" do
      run_late(20)
      expect { nx.wait }.to nap(10)
    end

    it "registers a deadline to be back in wait within 5 minutes and hops to delayed when run more than 20 seconds late" do
      run_late(21)
      expect { nx.wait }.to hop("delayed", nap: 10)
      frame = st.stack.first
      expect(frame["deadline_target"]).to eq "wait"
      expect(Time.new(frame["deadline_at"])).to be_within(5).of(Time.now + 5 * 60)
    end
  end

  describe "#delayed" do
    it "hops to recovering when run up to 20 seconds late" do
      run_late(20)
      expect { nx.delayed }.to hop("recovering", nap: 10)
    end

    it "naps when run more than 20 seconds late" do
      run_late(21)
      expect { nx.delayed }.to nap(10)
    end
  end

  describe "#recovering" do
    it "hops to delayed when run more than 20 seconds late" do
      run_late(21)
      expect { nx.recovering }.to hop("delayed", nap: 10)
    end

    it "naps until it has run on time for a minute" do
      st.stack.first["last_label_changed_at"] = st.time_string(Time.now - 50)
      run_late(20)
      expect { nx.recovering }.to nap(10)
    end

    it "hops to wait after running on time for a minute" do
      st.stack.first["last_label_changed_at"] = st.time_string(Time.now - 60)
      run_late(20)
      expect { nx.recovering }.to hop("wait", nap: 10)
    end
  end
end
