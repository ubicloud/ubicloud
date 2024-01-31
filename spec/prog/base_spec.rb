# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::Base do
  it "can bud and reap" do
    parent = Strand.create_with_id(prog: "Test", label: "budder")
    expect {
      parent.unsynchronized_run
      parent.reload
    }.to change { parent.load.leaf? }.from(true).to(false)

    child_id = parent.children.first.id
    Semaphore.incr(child_id, :should_get_deleted)

    expect {
      # Execution donated to child sets the exitval.
      parent.run

      # Parent notices exitval is set and reaps the child.
      parent.run
    }.to change { parent.load.leaf? }.from(false).to(true).and change {
      Semaphore.where(strand_id: child_id).empty?
    }.from(false).to(true).and change {
      parent.children.empty?
    }.from(false).to(true).and change {
      Strand[child_id].nil?
    }.from(false).to(true)
  end

  it "keeps children array state in sync even in consecutive-run mode" do
    parent = Strand.create_with_id(prog: "Test", label: "reap_exit_no_children")
    Strand.create_with_id(parent_id: parent.id, prog: "Test", label: "popper")
    expect(parent).to receive(:unsynchronized_run).twice.and_call_original
    parent.run(10)
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
    st = Strand.create_with_id(prog: "Test", label: "pusher1")
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

  it "can push new subject_id" do
    st = Strand.create_with_id(prog: "Test", label: "push_subject_id")
    st.run
    expect(st.stack.first["subject_id"]).not_to eq(st.id)
  end

  it "requires a symbol for hop" do
    expect {
      Strand.new(prog: "Test", label: "invalid_hop").unsynchronized_run
    }.to raise_error RuntimeError, "BUG: #hop only accepts a symbol"
  end

  it "requires valid label for hop" do
    expect {
      Strand.new(prog: "Test", label: :invalid_hop_target).unsynchronized_run
    }.to raise_error RuntimeError, "BUG: not valid hop target"
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

  it "calls before_run if it is available" do
    st = Strand.create_with_id(prog: "Prog::Vm::Nexus", label: "wait")
    prg = instance_double(Prog::Vm::Nexus)
    expect(st).to receive(:load).and_return(prg)
    expect(prg).to receive(:before_run)
    expect(prg).to receive(:wait).and_raise(Prog::Base::Nap.new(30))
    st.unsynchronized_run
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

    it "resolves the page of the budded prog when pop" do
      st = Strand.create_with_id(prog: "Test", label: :set_popping_deadline_via_bud)
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
      page_id = Prog::PageNexus.assemble("dummy-summary", [st.ubid], "Deadline", st.id, st.prog, :napper).id

      st.stack.first["deadline_target"] = :napper
      st.stack.first["deadline_at"] = Time.now - 1

      expect {
        st.unsynchronized_run
        Strand[page_id].unsynchronized_run
        Strand[page_id].unsynchronized_run
      }.to change { Page.active.count }.from(1).to(0)
    end

    it "resolves the page once a new deadline is registered" do
      st = Strand.create_with_id(prog: "Test", label: :start)
      page_id = Prog::PageNexus.assemble("dummy-summary", [st.ubid], "Deadline", st.id, st.prog, :napper).id

      st.stack.first["deadline_target"] = :napper
      st.stack.first["deadline_at"] = Time.now - 1

      st.update(label: :set_popping_deadline2)

      expect {
        st.unsynchronized_run

        page_id = Page.first.id
        Strand[page_id].unsynchronized_run
        Strand[page_id].unsynchronized_run
      }.to change { Page.active.count }.from(1).to(0)
    end

    it "deletes the deadline information once the target is reached" do
      st = Strand.create_with_id(prog: "Test", label: :napper)
      st.stack.first["deadline_target"] = :napper
      st.stack.first["deadline_at"] = Time.now - 1

      expect(st.stack.first).to receive(:delete).with("deadline_target")
      expect(st.stack.first).to receive(:delete).with("deadline_at")

      st.unsynchronized_run
    end
  end
end
