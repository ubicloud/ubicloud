# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Ember::Nexus do
  subject(:nx) { described_class.new(ember.strand) }

  let(:host) { create_ember_host }
  let(:ember) do
    c = create_ember(state: "running", vm_host_id: host.id, slot: 3)
    Strand.create_with_id(c, prog: "Ember::Nexus", label: "wait")
    c.reload
  end

  describe "#wait" do
    it "naps when there is nothing to do" do
      expect { nx.wait }.to nap(described_class::WAIT_SECONDS)
    end

    it "hops to destroy when asked" do
      ember.incr_destroy
      expect { nx.wait }.to hop("destroy")
    end

    it "hops to reconcile after a failed synchronous call" do
      ember.incr_checkup
      expect { nx.wait }.to hop("reconcile")
      expect(ember.reload.checkup_set?(cached: false)).to be false
    end

    it "hops to pause when asked" do
      ember.incr_pause
      expect { nx.wait }.to hop("pause")
      expect(ember.reload.pause_set?(cached: false)).to be false
    end

    it "pauses an ember nothing has touched for longer than its timeout" do
      ember.update(last_activity_at: Time.now - ember.idle_timeout_seconds - 1)
      expect { nx.wait }.to hop("pause")
    end

    it "decides nothing about an ember the synchronous path is still placing" do
      # A create that is mid-placement owns the row; expiring or pausing it
      # here would leave the placement writing to something that is gone.
      ember.update(state: "creating", expires_at: Time.now - 60,
        last_activity_at: Time.now - 3600, state_changed_at: Time.now)
      expect { nx.wait }.to nap(described_class::WAIT_SECONDS)
      expect(ember.reload.semaphores).to be_empty
    end

    it "asks the host what happened to a create that never finished" do
      ember.update(state: "creating",
        state_changed_at: Time.now - described_class::TRANSITION_GRACE_SECONDS - 1)
      expect { nx.wait }.to hop("reconcile")

      # And reconcile has to resolve it, or the two labels loop forever.
      nx.ember.update(vm_host_id: nil)
      expect { nx.reconcile }.to hop("wait")
      expect(ember.reload.state).to eq("paused")
    end

    it "destroys an unclaimed ember once it expires" do
      ember.update(expires_at: Time.now - 1)
      expect { nx.wait }.to nap(0)
      expect(ember.reload.destroy_set?(cached: false)).to be true
    end

    it "leaves a protected ember alone even when expired" do
      ember.update(expires_at: Time.now - 1, protected: true, last_activity_at: Time.now)
      expect { nx.wait }.to nap(described_class::WAIT_SECONDS)
      expect(ember.reload.destroy_set?(cached: false)).to be false
    end
  end

  describe "#pause" do
    it "pauses through the synchronous path and goes back to waiting" do
      expect(EmberOperations).to receive(:pause).with(ember)
      expect { nx.pause }.to hop("wait")
    end

    it "goes back to waiting when it is no longer running" do
      ember.update(state: "paused")
      expect(EmberOperations).not_to receive(:pause)
      expect { nx.pause }.to hop("wait")
    end

    it "reconciles when the host call fails" do
      expect(EmberOperations).to receive(:pause).and_raise(ember_command_crash("gone"))
      expect { nx.pause }.to hop("reconcile")
    end
  end

  describe "#reconcile" do
    it "believes the host when it says the ember is running" do
      ember.update(state: "creating")
      on_ember_command { |cmd, kw|
        expect([cmd, kw[:ember]]).to eq(["describe", ember.ubid])
        {"state" => "running", "slot" => 9, "ip6" => "2a01:db8::9"}
      }
      expect { nx.reconcile }.to hop("wait")
      expect(ember.reload.state).to eq("running")
      expect(ember.slot).to eq(9)
    end

    it "marks the ember paused when the host has no such VM" do
      on_ember_command { {"state" => "absent"} }
      expect { nx.reconcile }.to hop("wait")
      expect(ember.reload.state).to eq("paused")
      expect(ember.vm_host_id).to be_nil
    end

    it "treats a missing state the same as absent" do
      on_ember_command { {} }
      expect { nx.reconcile }.to hop("wait")
      expect(ember.reload.state).to eq("paused")
    end

    it "waits rather than fighting a host that is mid-flight" do
      on_ember_command { {"state" => "restoring"} }
      expect { nx.reconcile }.to nap(5)
    end

    it "retries when the host cannot be reached" do
      on_ember_command { raise ember_command_crash("timeout") }
      expect { nx.reconcile }.to nap(30)
    end

    it "corrects an ember that thinks it is running on no host at all" do
      ember.update(vm_host_id: nil)
      expect { nx.reconcile }.to hop("wait")
      expect(ember.reload.state).to eq("paused")
    end

    it "leaves a paused, hostless ember as it is" do
      ember.update(vm_host_id: nil, state: "paused")
      expect { nx.reconcile }.to hop("wait")
      expect(ember.reload.state).to eq("paused")
    end
  end

  describe "#destroy" do
    it "tells the host to destroy the VM, then removes the row and the volume" do
      volume_id = ember.detachable_volume.id
      on_ember_command { |cmd, kw|
        expect([cmd, JSON.parse(kw[:stdin])["delete_volume"]]).to eq(["destroy", false])
        {"destroyed" => true}
      }
      expect { nx.destroy }.to exit({"msg" => "ember destroyed"})
      expect(Ember[ember.id]).to be_nil
      expect(DetachableVolume[volume_id].destroy_set?(cached: false)).to be true
    end

    it "keeps trying rather than leaking a slot" do
      on_ember_command { raise ember_command_crash("down") }
      expect { nx.destroy }.to nap(15)
      expect(Ember[ember.id]).not_to be_nil
    end

    it "destroys an ember that is not on a host" do
      ember.update(vm_host_id: nil)
      expect { nx.destroy }.to exit({"msg" => "ember destroyed"})
      expect(Ember[ember.id]).to be_nil
    end
  end
end
