# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Ember::Pool do
  subject(:nx) { described_class.new(strand) }

  let(:pool) { create_ember_pool(workload: "fake") }
  let(:strand) { pool.strand }
  let(:host) { create_ember_host }
  # Every host/bin/ember command the pool ran but list, as [command, host id,
  # keywords].
  let(:calls) { [] }
  # What each host's list says its slots hold, by host id.
  let(:held) { Hash.new { [] } }

  let!(:template) do
    t = create_ember_template(workload: "fake", cpu_signature: host.cpu_signature)
    EmberTemplateHost.create(ember_template_id: t.id, vm_host_id: host.id, state: "ready")
    t
  end

  before do
    stub_ember_workload
    host
    on_ember_command { |cmd, kw, sshable| answer(cmd, kw, sshable) }
    allow(Config).to receive(:ember_service_project_id).and_return(Project.create(name: "ember-service").id)
  end

  def answer(cmd, kw, sshable)
    slots = held[sshable.id].map { {"slot" => 0, "kind" => "blank", "id" => it, "volume_id" => it} }
    return {"slots" => slots} if cmd == "list"
    calls << [cmd, sshable.id, kw]
    {}
  end

  describe ".assemble" do
    it "creates the location's pool and its strand" do
      p = described_class.assemble(Location::HETZNER_FSN1_ID, workload: "fake")
      expect(p.target).to eq(Config.ember_pool_target)
      expect(Strand[p.id].label).to eq("start")
    end

    it "accepts a target override" do
      expect(described_class.assemble(Location::HETZNER_FSN1_ID, workload: "fake", target: 9).target).to eq(9)
    end

    # One pool per location, so assembling twice must not make a second.
    it "returns the existing pool rather than making another" do
      first = described_class.assemble(Location::HETZNER_FSN1_ID, workload: "fake")
      expect(described_class.assemble(Location::HETZNER_FSN1_ID, workload: "fake").id).to eq(first.id)
      expect(EmberPool.count).to eq(1)
    end

    it "refuses a location that does not exist" do
      expect { described_class.assemble(Vm.generate_uuid, workload: "fake") }.to raise_error(RuntimeError, /no such location/)
    end
  end

  describe "#start" do
    it "goes straight to waiting" do
      expect { nx.start }.to hop("wait")
    end
  end

  describe "#wait" do
    it "hops to destroy when asked" do
      pool.incr_destroy
      expect { nx.wait }.to hop("destroy")
    end

    it "otherwise checks the pool" do
      expect { nx.wait }.to hop("refill")
    end
  end

  describe "#refill" do
    it "creates one blank at a time when the pool is short, and owns its volume" do
      pool.update(target: 4)
      on_ember_command { |cmd, kw, sshable|
        next answer(cmd, kw, sshable) if cmd == "list"
        calls << cmd
        payload = JSON.parse(kw[:stdin])
        expect(payload.slice("template_id", "workload", "guest", "cpu_percent_limit"))
          .to eq({"template_id" => template.ubid, "workload" => "fake", "guest" => {}, "cpu_percent_limit" => 50})
        expect(payload["volume"]["source"]).to eq({"type" => "new", "image" => template.data_image})
        # The volume is the control plane's, named and keyed by it, because a
        # claim keeps it.
        expect(DetachableVolume[payload["volume"]["id"]]).not_to be_nil
        expect(payload["volume"]["kek"]).not_to be_nil
        expect(payload["volume"]["wrapped_xts"]).not_to be_nil
        {}
      }
      expect { nx.refill }.to nap(described_class::POLL_SECONDS)
      expect(calls).to eq(["create-blank"])
      expect(DetachableVolume.first.vm_host_id).to eq(host.id)
      # A claim hands the volume to an ember, whose destroy goes through this.
      expect(DetachableVolume.first.strand.prog).to eq("Storage::DetachableVolumeNexus")
    end

    it "drops the volume row when the blank never came up" do
      on_ember_command { |cmd, kw, sshable|
        next answer(cmd, kw, sshable) if cmd == "list"
        raise ember_command_crash("no")
      }
      expect { nx.refill }.to nap(described_class::POLL_SECONDS)
      expect(DetachableVolume.count).to eq(0)
      expect(Strand.where(prog: "Storage::DetachableVolumeNexus").count).to eq(0)
    end

    it "does nothing when the pool is full" do
      held[host.id] = add_ember_blanks(host, 4).map(&:ubid)
      pool.update(target: 4)
      expect { nx.refill }.to nap(described_class::POLL_SECONDS)
      expect(calls).to be_empty
    end

    it "does not fill a disabled pool" do
      pool.update(enabled: false)
      expect { nx.refill }.to nap(described_class::POLL_SECONDS)
      expect(calls).to be_empty
    end

    it "does nothing when no host in the location has room" do
      host.update(total_mem_gib: 8)
      expect { nx.refill }.to nap(described_class::POLL_SECONDS)
      expect(calls).to be_empty
    end

    it "ignores a host that is drained" do
      host.update(allocation_state: "draining")
      expect { nx.refill }.to nap(described_class::POLL_SECONDS)
      expect(calls).to be_empty
    end

    # The pool spreads rather than piling onto whichever host answered first.
    it "puts the blank on the host holding the fewest" do
      held[host.id] = add_ember_blanks(host, 3).map(&:ubid)
      emptier = create_ember_host
      held[emptier.id] = add_ember_blanks(emptier, 1).map(&:ubid)
      EmberTemplateHost.create(ember_template_id: template.id, vm_host_id: emptier.id, state: "ready")
      pool.update(target: 10)

      expect { nx.refill }.to nap(described_class::POLL_SECONDS)
      expect(calls.map { it.first(2) }).to eq([["create-blank", emptier.id]])
    end

    it "does nothing when the host has no template it can run" do
      EmberTemplateHost.where(vm_host_id: host.id).destroy
      expect { nx.refill }.to nap(described_class::POLL_SECONDS)
      expect(calls).to be_empty
    end

    it "does not use a template built for another CPU" do
      template.update(cpu_signature: "GenuineIntel-6-143-8/53.0")
      expect { nx.refill }.to nap(described_class::POLL_SECONDS)
      expect(calls).to be_empty
    end

    it "keeps going when the host refuses" do
      on_ember_command { |cmd, kw, sshable|
        next answer(cmd, kw, sshable) if cmd == "list"
        raise ember_command_failure("slot_exhausted")
      }
      expect { nx.refill }.to nap(described_class::POLL_SECONDS)
    end

    describe "reconciling blanks" do
      def stale_blank
        add_ember_blanks(host, 1).first.tap { it.update(created_at: Time.now - 3600) }
      end

      before { pool.update(target: 0) }

      it "destroys volume rows for blanks the host no longer holds" do
        stale = stale_blank
        expect { nx.refill }.to nap(described_class::POLL_SECONDS)
        expect(stale.reload.semaphores.map(&:name)).to include("destroy")
      end

      it "keeps the blanks the host still holds" do
        stale = stale_blank
        held[host.id] = [stale.ubid]
        expect { nx.refill }.to nap(described_class::POLL_SECONDS)
        expect(stale.reload.semaphores).to be_empty
      end

      it "leaves a blank being made right now alone" do
        fresh = add_ember_blanks(host, 1).first
        expect { nx.refill }.to nap(described_class::POLL_SECONDS)
        expect(fresh.reload.semaphores).to be_empty
      end

      # Reconciling against an answer that never came would destroy the pool.
      it "leaves the blanks alone when the host cannot be asked" do
        stale = stale_blank
        on_ember_command { raise ember_command_crash("down") }
        expect { nx.refill }.to nap(described_class::POLL_SECONDS)
        expect(stale.reload.semaphores).to be_empty
      end

      it "does not touch the volume of a blank that an ember has claimed" do
        ember = create_ember(project_id: Config.ember_service_project_id)
        ember.detachable_volume.update(vm_host_id: host.id, created_at: Time.now - 3600)
        expect { nx.refill }.to nap(described_class::POLL_SECONDS)
        expect(ember.detachable_volume.reload.semaphores).to be_empty
      end
    end

    describe "retiring aged blanks" do
      before { pool.update(target: 0) }

      it "retires a blank that has aged past its template, and its volume" do
        old = add_ember_blanks(host, 1).first
        old.update(created_at: Time.now - Config.ember_blank_max_age_seconds - 1)
        held[host.id] = [old.ubid]
        expect { nx.refill }.to nap(described_class::POLL_SECONDS)
        expect(calls.map { |cmd, _, kw| [cmd, kw[:blank]] }).to eq([["destroy", old.ubid]])
        expect(old.reload.semaphores.map(&:name)).to include("destroy")
      end

      it "keeps a blank that is still young, and says so when retiring fails" do
        young, old = add_ember_blanks(host, 2)
        old.update(created_at: Time.now - Config.ember_blank_max_age_seconds - 1)
        held[host.id] = [young.ubid, old.ubid]
        on_ember_command { |cmd, kw, sshable|
          next answer(cmd, kw, sshable) if cmd == "list"
          calls << [cmd, kw[:blank]]
          raise ember_command_crash("busy")
        }
        expect { nx.refill }.to nap(described_class::POLL_SECONDS)
        expect(calls).to eq([["destroy", old.ubid]])
        expect(old.reload.semaphores).to be_empty
      end
    end
  end

  describe "#destroy" do
    it "removes the pool" do
      expect { nx.destroy }.to exit({"msg" => "ember pool destroyed"})
      expect(EmberPool[pool.id]).to be_nil
    end
  end
end
