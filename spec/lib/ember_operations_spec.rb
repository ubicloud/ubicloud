# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe EmberOperations do
  let(:project) { Project.create(name: "ember-ops") }
  let(:location) { Location[Location::HETZNER_FSN1_ID] }
  let(:template) { create_ember_template(workload: "fake") }
  let(:host) { create_ember_host }

  def make_host_ready(a_host = host, blank: 0, a_template: template)
    unless EmberTemplateHost[ember_template_id: a_template.id, vm_host_id: a_host.id]
      EmberTemplateHost.create(ember_template_id: a_template.id, vm_host_id: a_host.id, state: "ready")
    end
    add_ember_blanks(a_host, blank)
    a_host
  end

  def started(slot: 3, ip6: "2a01:db8::3", caught_up: true)
    {"slot" => slot, "ip6" => ip6, "caught_up" => caught_up, "phases_ms" => {"total" => 462}}
  end

  # An ember with no workload row. What runs inside is not this layer's
  # business: it hands the host whatever the workload says the guest needs, so
  # the spec stands in for one with an opaque payload.
  def create_ember_op(**)
    described_class.create(project_id: project.id, location:, workload: "fake", version: "18", **) { nil }
  end

  before do
    stub_ember_workload
    allow_any_instance_of(Ember).to receive(:guest_config).and_return({"opaque" => "guest"})
  end

  describe ".create" do
    before { make_host_ready }

    it "creates a running ember with its own volume and strand" do
      commands = []
      on_ember_command { |cmd, kw|
        commands << [cmd, kw[:timeout]]
        started
      }

      ember = create_ember_op

      expect(commands).to eq([["create", described_class::HOST_TIMEOUT]])
      expect(ember.state).to eq("running")
      expect(ember.vm_host_id).to eq(host.id)
      expect(ember.slot).to eq(3)
      expect(ember.detachable_volume.vm_host_id).to eq(host.id)
      expect(ember.strand.prog).to eq("Ember::Nexus")
      expect(ember.name).to eq("ember-#{ember.ubid[2, 10]}")
    end

    it "claims a warm blank when the host has one, rather than restoring" do
      make_host_ready(blank: 2)
      commands = []
      on_ember_command { |cmd|
        commands << cmd
        started
      }

      expect(create_ember_op.state).to eq("running")
      expect(commands).to eq(["claim-blank"])
    end

    it "restores when the last blank went to somebody else in the meantime" do
      make_host_ready(blank: 1)
      commands = []
      on_ember_command { |cmd|
        commands << cmd
        raise ember_command_failure("slot_exhausted") if cmd == "claim-blank"
        started
      }

      expect(create_ember_op.state).to eq("running")
      expect(commands).to eq(["claim-blank", "create"])
    end

    it "does not fall back to a restore when the claim failed for another reason" do
      make_host_ready(blank: 1)
      commands = []
      on_ember_command { |cmd|
        commands << cmd
        raise Sshable::SshError.new("sudo host/bin/ember", "", "boom", 1, nil)
      }

      expect { create_ember_op }.to raise_error(described_class::NoCapacity, /boom/)
      expect(commands).to eq(["claim-blank"])
    end

    it "keeps its own volume when the claimed one is not a row it can find" do
      make_host_ready(blank: 1)
      on_ember_command { started.merge("volume_id" => Ember.generate_ubid.to_s) }
      ember = create_ember_op
      expect(ember.detachable_volume).not_to be_nil
    end

    it "takes on the claimed blank's volume and drops the one it made" do
      make_host_ready
      blank_volume = add_ember_blanks(host, 1).first
      on_ember_command { started.merge("volume_id" => blank_volume.ubid) }

      ember = create_ember_op
      expect(ember.reload.detachable_volume.id).to eq(blank_volume.id)
      expect(blank_volume.reload.project_id).to eq(project.id)
      expect(DetachableVolume.count).to eq(1)
    end

    it "passes the volume's stripe source through, and the guest payload untouched" do
      on_ember_command { |_, kw|
        payload = JSON.parse(kw[:stdin])
        expect(payload["volume"]["source"]).to eq({"type" => "new", "image" => "cell-pgdata-18"})
        expect(payload["guest"]).to eq({"opaque" => "guest"})
        expect(payload["cpu_percent_limit"]).to eq(50)
        started
      }
      create_ember_op
    end

    it "creates the workload row inside the same transaction as the ember" do
      on_ember_command { started }
      seen = nil
      described_class.create(project_id: project.id, location:, workload: "fake", version: "18") {
        seen = [it.class, it.state, DB.in_transaction?]
      }
      expect(seen).to eq([Ember, "creating", true])
    end

    it "refuses when the location has no ready template" do
      template.update(state: "building")
      expect { create_ember_op }
        .to raise_error(described_class::NoCapacity, /no ready fake 18 template/)
    end

    it "picks the newest ready template" do
      newer = create_ember_template(workload: "fake", data_image: "cell-pgdata-18-v2", created_at: Time.now + 60)
      EmberTemplateHost.create(ember_template_id: newer.id, vm_host_id: host.id, state: "ready")
      on_ember_command { started }

      expect(create_ember_op.ember_template_id).to eq(newer.id)
    end

    it "tries the next host when one fails, and leaves the ember running" do
      second = make_host_ready(create_ember_host(total_mem_gib: 16))
      asked = []
      on_ember_command { |_, _, sshable|
        asked << sshable.id
        raise ember_command_failure("slot_exhausted") if asked.size == 1
        started
      }

      ember = create_ember_op
      expect(ember.state).to eq("running")
      expect(asked.uniq.size).to eq(2)
      expect(ember.vm_host_id).to eq(asked.last)
      expect([host.id, second.id]).to include(ember.vm_host_id)
    end

    it "gives up after three hosts and asks the nexus to reconcile" do
      4.times { make_host_ready(create_ember_host) }
      attempts = 0
      on_ember_command {
        attempts += 1
        raise ember_command_failure("slot_exhausted")
      }

      expect { create_ember_op }
        .to raise_error(described_class::NoCapacity, /could not place/)
      expect(attempts).to eq(3)
      expect(Ember.first.checkup_set?(cached: false)).to be true
    end

    it "refuses when no host can run the template" do
      EmberTemplateHost.where(vm_host_id: host.id).destroy
      expect { create_ember_op }
        .to raise_error(described_class::NoCapacity, /could not place/)
    end
  end

  describe ".resume" do
    # Built eagerly, so the create call does not consume a stub meant for the
    # resume under test.
    attr_reader :ember

    before do
      make_host_ready
      on_ember_command { started }
      @ember = create_ember_op
      # Pause it without involving a host, so resume is tested alone.
      @ember.update(state: "paused", vm_host_id: nil, slot: nil)
      @ember.detachable_volume.update(vm_host_id: host.id)
    end

    it "brings a paused ember back on the host holding its volume" do
      described_class.resume(ember)
      expect(ember.reload.state).to eq("running")
      expect(ember.detachable_volume.reload.vm_host_id).to eq(host.id)
    end

    it "bumps the generation so a stale call from before can be rejected" do
      before_generation = ember.generation
      described_class.resume(ember)
      expect(ember.reload.generation).to be > before_generation
    end

    it "is a no-op when the ember is already running" do
      ember.update(state: "running")
      on_ember_command { raise "no host call expected" }
      expect(described_class.resume(ember).state).to eq("running")
    end

    it "marks the volume as still catching up when the host says so" do
      on_ember_command { started(caught_up: false) }
      described_class.resume(ember)
      expect(ember.detachable_volume.reload.catch_up_set?).to be true
    end

    it "only tries the host that holds the data" do
      other = make_host_ready(create_ember_host, blank: 10)
      expect(VmHost).to receive(:ember_candidates_for).and_return([other, host])
      asked = []
      on_ember_command { |_, _, sshable|
        asked << sshable.id
        raise ember_command_failure("slot_exhausted")
      }
      expect { described_class.resume(ember) }.to raise_error(described_class::NoCapacity, /could not place/)
      expect(asked).to eq([host.id])
    end

    it "refuses at once when the host holding its volume cannot take it" do
      other = make_host_ready(create_ember_host)
      expect(VmHost).to receive(:ember_candidates_for).and_return([other])
      on_ember_command { raise "no host call expected" }
      expect { described_class.resume(ember) }
        .to raise_error(described_class::NoCapacity, /#{host.ubid}, which holds its volume, cannot take it/)
    end
  end

  describe ".pause" do
    attr_reader :ember

    before do
      make_host_ready
      on_ember_command { started }
      @ember = create_ember_op
    end

    it "stops the ember and leaves the volume on the host" do
      on_ember_command { |cmd, kw|
        expect([cmd, kw[:timeout]]).to eq(["pause", described_class::PAUSE_TIMEOUT])
        {"clean" => true, "caught_up" => true}
      }
      described_class.pause(ember)

      expect(ember.reload.state).to eq("paused")
      expect(ember.vm_host_id).to be_nil
      expect(ember.slot).to be_nil
      expect(ember.detachable_volume.reload.vm_host_id).to eq(host.id)
    end

    it "leaves the volume catching up when it had not finished" do
      on_ember_command { {"clean" => true, "caught_up" => false} }
      described_class.pause(ember)
      expect(ember.detachable_volume.reload.catch_up_set?).to be true
    end

    it "is a no-op when the ember is not running" do
      ember.update(state: "paused")
      on_ember_command { raise "no host call expected" }
      expect(described_class.pause(ember).state).to eq("paused")
    end

    it "asks the nexus to reconcile when the host call fails" do
      on_ember_command { raise Sshable::SshError.new("sudo host/bin/ember pause", "", "gone", 1, nil) }
      expect { described_class.pause(ember) }.to raise_error(Sshable::SshError)
      expect(ember.reload.checkup_set?(cached: false)).to be true
    end
  end

  it "commits the state change before calling the host" do
    # The measured failure mode is holding a pooled connection for the whole
    # host call: with the default web pool of four, a 500 ms create caps the
    # process at about eight per second. The specs run inside a transaction of
    # their own, so what can be asserted here is the ordering: the row is
    # already written, with its pre-call state, by the time the host is asked.
    make_host_ready
    on_ember_command {
      row = DB[:ember].first
      expect(row).not_to be_nil
      expect(row[:state]).to eq("creating")
      started
    }
    create_ember_op
  end
end
