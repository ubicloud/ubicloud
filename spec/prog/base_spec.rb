# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::Base do
  it "can bud and reap" do
    parent = Strand.create_with_id(prog: "Test", label: "budder")
    expect {
      parent.unsynchronized_run
      parent.reload
    }.to change { parent.load.leaf? }.from(true).to(false)

    expect {
      # Execution donated to child sets the exitval.
      parent.run

      # Parent notices exitval is set and reaps the child.
      parent.run
    }.to change { parent.load.leaf? }.from(false).to(true)
  end

  describe "#pop" do
    it "can reject unanticipated values" do
      expect {
        Strand.new(prog: "Test", label: "bad_pop").unsynchronized_run
      }.to raise_error RuntimeError, "BUG: must pop with string or hash"
    end

    it "crashes is the stack is malformed" do
      expect {
        Strand.new(prog: "Test", label: "popper", stack: [{}] * 2).unsynchronized_run
      }.to raise_error RuntimeError, "BUG: expect no stacks exceeding depth 1 with no back-link"
    end
  end

  it "can push prog and frames on the stack" do
    st = Strand.create_with_id(prog: "Test", label: :pusher1)
    expect {
      st.run
    }.to change { st.label }.from("pusher1").to("pusher2")
    expect(st.retval).to be_nil

    expect {
      st.run
    }.to change { st.label }.from("pusher2").to "pusher3"
    expect(st.retval).to be_nil

    expect {
      st.run
    }.to change { st.label }.from("pusher3").to "pusher2"
    expect(st.retval).to eq({"msg" => "3"})

    expect {
      st.run
    }.to change { st.label }.from("pusher2").to "pusher1"
    expect(st.retval).to eq({"msg" => "2"})

    st.run
    expect(st.exitval).to eq({"msg" => "1"})

    expect { st.run }.to raise_error "already deleted"
    expect { st.reload }.to raise_error Sequel::NoExistingObject
  end

  it "can nap" do
    st = Strand.create_with_id(prog: "Test", label: "napper")
    ante = st.schedule
    st.run
    post = st.schedule
    expect(post - ante).to be > 121
  end

  it "requires a symbol for hop" do
    expect {
      Strand.new(prog: "Test", label: "invalid_hop").unsynchronized_run
    }.to raise_error RuntimeError, "BUG: #hop only accepts a symbol"
  end

  it "can manipulate semaphores" do
    st = Strand.create_with_id(prog: "Test", label: "increment_semaphore")
    expect {
      st.run
    }.to change { Semaphore.where(strand_id: st.id).any? }.from(false).to(true)

    st.label = "decrement_semaphore"
    expect {
      st.unsynchronized_run
    }.to change { Semaphore.where(strand_id: st.id).any? }.from(true).to(false)
  end

  context "when rendering FlowControl strings" do
    it "can render hop" do
      expect(
        described_class::Hop.new("OldProg", "old_label",
          Strand.new(prog: "NewProg", label: "new_label")).to_s
      ).to eq("hop OldProg#old_label -> NewProg#new_label")
    end

    it "can render nap" do
      expect(described_class::Nap.new("10").to_s).to eq("nap for 10 seconds")
    end

    it "can render exit" do
      expect(described_class::Exit.new(
        Strand.new(prog: "TestProg", label: "exiting_label"), {"msg" => "done"}
      ).to_s).to eq('Strand exits from TestProg#exiting_label with {"msg"=>"done"}')
    end
  end

  context "with deadlines" do
    it "registers a deadline only if the current deadline is nil, later or to a different target" do
      st = Strand.create_with_id(prog: "Test", label: :set_expired_deadline)

      # register if current deadline is nil
      expect {
        st.unsynchronized_run
      }.to change { st.stack.first["deadline_at"] }

      # register if current deadline is further in the time
      st.label = :set_expired_deadline
      st.stack.first["deadline_at"] = Time.now + 30
      expect {
        st.unsynchronized_run
      }.to change { st.stack.first["deadline_at"] }

      # register if the target is different
      st.label = :set_expired_deadline
      st.stack.first["deadline_target"] = :napper
      expect {
        st.unsynchronized_run
      }.to change { st.stack.first["deadline_at"] }
      st.unsynchronized_run

      # ignore if new deadline is further in the time and target is same
      st.label = :set_expired_deadline
      st.stack.first["deadline_at"] = Time.now - 60
      st.stack.first["deadline_target"] = :pusher2
      expect {
        st.unsynchronized_run
      }.not_to change { st.stack.first["deadline_at"] }
    end

    it "triggers a page exactly once when deadline is expired" do
      st = Strand.create_with_id(prog: "Test", label: :set_expired_deadline)
      st.unsynchronized_run
      expect {
        st.unsynchronized_run
      }.to change { Page.active.count }.from(0).to(1)

      expect {
        st.unsynchronized_run
      }.not_to change { Page.active.count }.from(1)
    end

    it "resolves the page if the frame is popped" do
      st = Strand.create_with_id(prog: "Test", label: :set_popping_deadline1)
      st.unsynchronized_run
      st.unsynchronized_run
      expect {
        st.unsynchronized_run
      }.to change { Page.active.count }.from(0).to(1)

      expect {
        st.unsynchronized_run

        page_id = Page.first.id
        Strand[page_id].unsynchronized_run
        Strand[page_id].unsynchronized_run
      }.to change { Page.active.count }.from(1).to(0)
    end

    it "resolves the page once the target is reached" do
      st = Strand.create_with_id(prog: "Test", label: :napper)
      page_id = Prog::PageNexus.assemble("dummy-summary").id

      st.stack.first["deadline_target"] = :napper
      st.stack.first["deadline_at"] = Time.now - 1
      st.stack.first["page_id"] = page_id

      expect {
        st.unsynchronized_run
        Strand[page_id].unsynchronized_run
        Strand[page_id].unsynchronized_run
      }.to change { Page.active.count }.from(1).to(0)
    end

    it "resolves the page once a new deadline is registered" do
      st = Strand.create_with_id(prog: "Test", label: :start)
      page_id = Prog::PageNexus.assemble("dummy-summary").id

      st.stack.first["deadline_target"] = :napper
      st.stack.first["deadline_at"] = Time.now - 1
      st.stack.first["page_id"] = page_id

      st.update(label: :set_popping_deadline2)

      expect {
        st.unsynchronized_run

        page_id = Page.first.id
        Strand[page_id].unsynchronized_run
        Strand[page_id].unsynchronized_run
      }.to change { Page.active.count }.from(1).to(0)
    end

    it "doesn't try to resolve a page if it isn't exist" do
      st = Strand.create_with_id(prog: "Test", label: :napper)
      st.stack.first["deadline_target"] = :napper
      st.stack.first["deadline_at"] = Time.now - 1

      expect(st.stack.first).not_to receive(:delete).with("page_id")

      st.unsynchronized_run
    end
  end
end
