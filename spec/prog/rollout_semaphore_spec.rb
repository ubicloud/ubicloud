# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::RolloutSemaphore do
  subject(:nx) { described_class.new(st) }

  let(:st) { described_class.assemble(semaphore: "resolve", ids: page_ids) }
  let(:pages) { Array.new(3) { Prog::PageNexus.assemble("test", ["test", it], []).subject } }
  let(:page_ids) { pages.map(&:id) }

  def reload_frame
    st.reload.stack.first
  end

  describe ".assemble" do
    it "creates strand with objects to rollout semaphore to" do
      expect(st.label).to eq("start")
      expect(st.prog).to eq("RolloutSemaphore")

      frame = st.stack.first
      expect(frame["semaphore"]).to eq("resolve")
      expect(frame["gap"]).to eq(60)
      expect(frame["initial_gap"]).to eq(300)
      expect(frame["initial_num"]).to eq(2)
      expect(frame["remaining"]).to eq(page_ids)
      expect(frame["next_increment_time"]).to be_within(5).of(Time.now.to_i)
    end

    it "raises for invalid semaphore" do
      expect { described_class.assemble(semaphore: "bad", ids: page_ids) }.to raise_error(RuntimeError)
    end
  end

  describe "#start" do
    it "naps when pause semaphore is set" do
      nx.incr_pause
      expect { nx.start }.to nap(60 * 60)
    end

    it "increments semaphore on next object and naps" do
      expect { nx.start }.to nap(295...305)
        .and change { pages.first.reload.resolve_set? }.from(false).to(true)
      expect(st.reload.stack[0]["next_increment_time"]).to be_within(5).of(Time.now.to_i + 300)
    end

    it "hops to destroy if there are no objects remaining" do
      refresh_frame(nx, new_values: {"remaining" => []})
      expect { nx.start }.to hop("destroy")
    end

    it "naps using regular gap after passing the initial number of records" do
      refresh_frame(nx, new_values: {"initial_num" => 0})
      expect { nx.start }.to nap(55...65)
        .and change { pages.first.reload.resolve_set? }.from(false).to(true)
      expect(st.reload.stack[0]["next_increment_time"]).to be_within(5).of(Time.now.to_i + 60)
    end

    it "naps if not yet at the next increment time" do
      refresh_frame(nx, new_values: {"next_increment_time" => Time.now.to_i + 10})
      expect { nx.start }.to nap(5...15)
    end
  end

  describe "#destroy" do
    it "exits if destroy semaphore is set" do
      nx.incr_destroy
      expect { nx.destroy }.to exit("msg" => "rollout completed")
    end

    it "naps otherwise" do
      expect { nx.destroy }.to nap(60 * 60 * 24 * 365)
    end
  end
end
