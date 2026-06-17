# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::RolloutSemaphore do
  subject(:nx) { described_class.new(st) }

  let(:st) { described_class.assemble(semaphore: "resolve", ids: page_ids) }
  let(:pages) { Array.new(3) { Prog::PageNexus.assemble("test", ["test", it], []).subject } }
  let(:page_ids) { pages.map(&:id) }

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
      expect(frame["increment"]).to be true
      expect(frame.fetch("wait_label")).to be true
      expect(frame.fetch("current")).to be_nil
    end

    it "supports gap, initial_gap, initial_range, increment, and wait_label arguments" do
      st = described_class.assemble(semaphore: "resolve", ids: page_ids, gap: 10, initial_gap: 15, initial_range: 1..5, increment: false, wait: "wait")
      expect(st.label).to eq("start")
      expect(st.prog).to eq("RolloutSemaphore")

      frame = st.stack.first
      expect(frame["semaphore"]).to eq("resolve")
      expect(frame["gap"]).to eq(10)
      expect(frame["initial_gap"]).to eq(15)
      expect(frame["initial_num"]).to eq(1)
      expect(frame["remaining"]).to eq(page_ids)
      expect(frame["next_increment_time"]).to be_within(5).of(Time.now.to_i)
      expect(frame["increment"]).to be false
      expect(frame["wait_label"]).to eq "wait"
      expect(frame.fetch("current")).to be_nil
    end

    it "raises for invalid semaphore" do
      expect { described_class.assemble(semaphore: "bad", ids: page_ids) }.to raise_error(RuntimeError, "Some classes do not support semaphores: Page")
    end
  end

  describe "#start" do
    it "naps when pause semaphore is set" do
      nx.incr_pause
      expect { nx.start }.to nap(60 * 60)
    end

    it "increments semaphore on next object and naps if not waiting" do
      refresh_frame(nx, new_values: {"wait_label" => false})
      expect { nx.start }.to nap(295...305)
        .and change { pages.first.reload.resolve_set? }.from(false).to(true)
      expect(st.stack[0]["next_increment_time"]).to be_within(5).of(Time.now.to_i + 300)
      expect(st.stack[0]["completed"]).to eq [page_ids[0]]
      expect(st.stack[0].fetch("current")).to be_nil
      expect(st.stack[0]["remaining"]).to eq page_ids[1..]
    end

    it "increments semaphore on next object and hops to wait_current" do
      expect { nx.start }.to hop("wait_current")
        .and change { pages.first.reload.resolve_set? }.from(false).to(true)
      expect(st.stack[0]["next_increment_time"]).to be_within(5).of(Time.now.to_i + 300)
      expect(st.stack[0]["completed"]).to eq []
      expect(st.stack[0]["current"]).to eq page_ids[0]
      expect(st.stack[0]["remaining"]).to eq page_ids[1..]
    end

    it "decrements semaphore on next object and naps if increment is not true" do
      pages.first.incr_resolve
      refresh_frame(nx, new_values: {"increment" => false})
      expect { nx.start }.to nap(295...305)
        .and change { pages.first.reload.resolve_set? }.from(true).to(false)
      expect(st.stack[0]["next_increment_time"]).to be_within(5).of(Time.now.to_i + 300)
      expect(st.stack[0]["completed"]).to eq [page_ids[0]]
      expect(st.stack[0].fetch("current")).to be_nil
      expect(st.stack[0]["remaining"]).to eq page_ids[1..]
    end

    it "hops to destroy if there are no objects remaining" do
      refresh_frame(nx, new_values: {"remaining" => []})
      expect { nx.start }.to hop("destroy")
    end

    it "naps using regular gap after passing the initial number of records" do
      refresh_frame(nx, new_values: {"initial_num" => 0})
      expect { nx.start }.to hop("wait_current")
        .and change { pages.first.reload.resolve_set? }.from(false).to(true)
      expect(st.stack[0]["next_increment_time"]).to be_within(5).of(Time.now.to_i + 60)
      expect(st.stack[0]["completed"]).to eq []
      expect(st.stack[0]["current"]).to eq page_ids[0]
      expect(st.stack[0]["remaining"]).to eq page_ids[1..]
    end

    it "naps if not yet at the next increment time" do
      refresh_frame(nx, new_values: {"next_increment_time" => Time.now.to_i + 10})
      expect { nx.start }.to nap(5...15)
    end
  end

  describe "#wait_current" do
    it "naps if semaphore still set for current strand" do
      Semaphore.incr(page_ids[0], "resolve")
      refresh_frame(nx, new_values: {"current" => page_ids[0]})
      expect { nx.wait_current }.to nap(6)
    end

    it "naps if current strand not at wait_label" do
      refresh_frame(nx, new_values: {"current" => page_ids[0], "wait_label" => "wait"})
      expect { nx.wait_current }.to nap(6)
    end

    it "hops to start if semaphore no longer set and wait label is not a string" do
      refresh_frame(nx, new_values: {"current" => page_ids[0]})
      expect { nx.wait_current }.to hop("start")
    end

    it "hops to start if current strand no longer exists" do
      Strand.where(id: page_ids[0]).destroy
      refresh_frame(nx, new_values: {"current" => page_ids[0]})
      expect { nx.wait_current }.to hop("start")
    end

    it "hops to start if current strand is at wait label" do
      refresh_frame(nx, new_values: {"current" => page_ids[0], "wait_label" => "start"})
      expect { nx.wait_current }.to hop("start")
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
