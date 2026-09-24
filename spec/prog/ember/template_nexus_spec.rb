# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Ember::TemplateNexus do
  subject(:nx) { described_class.new(strand) }

  let(:template) { create_ember_template(state: "building") }
  let(:strand) { Strand.create_with_id(template, prog: "Ember::TemplateNexus", label: "start") }
  let(:builder) { create_ember_host(cpu_signature: template.cpu_signature) }

  before { strand }

  describe ".assemble" do
    it "creates a building template with the configured defaults" do
      t = described_class.assemble(
        location_id: Location::HETZNER_FSN1_ID, cpu_signature: "sig",
        root_image: "root", data_image: "pgdata", workload: "postgres", version: "18",
      )
      expect(t.state).to eq("building")
      expect(t.memory_mib).to eq(Config.ember_default_memory_mib)
      expect(t.ch_version).to eq(Config.ember_ch_version)
      expect(Strand[t.id].label).to eq("start")
    end

    it "accepts an explicit memory size" do
      t = described_class.assemble(
        location_id: Location::HETZNER_FSN1_ID, cpu_signature: "sig", root_image: "r",
        data_image: "p", workload: "postgres", version: "18", memory_mib: 512,
      )
      expect(t.memory_mib).to eq(512)
    end
  end

  describe "#start" do
    it "goes straight to building" do
      expect { nx.start }.to hop("build")
    end
  end

  describe "#build" do
    it "asks every peer without a copy to build its own" do
      peer = create_ember_host(cpu_signature: template.cpu_signature)
      EmberTemplateHost.create(ember_template_id: template.id, vm_host_id: builder.id, state: "ready")
      asked = []
      on_ember_command { |cmd, kw, sshable|
        asked << [cmd, kw[:template], sshable.id]
        payload = JSON.parse(kw[:stdin])
        expect(payload["root_image"]).to eq(template.root_image)
        expect(payload["memory_mib"]).to eq(template.memory_mib)
        {"state" => "building"}
      }

      expect { nx.build }.to hop("wait_builds")
      expect(asked).to eq([["build-template", template.ubid, peer.id]])
      expect(EmberTemplateHost[ember_template_id: template.id, vm_host_id: peer.id].state).to eq("building")
    end

    it "waits when the location has no host that could build it" do
      expect { nx.build }.to nap(60)
    end

    it "does not use a host with a different CPU" do
      create_ember_host(cpu_signature: "GenuineIntel-6-143-8/53.0")
      expect { nx.build }.to nap(60)
    end

    it "records nothing for a host that will not start the build, and retries when none would" do
      builder
      on_ember_command { raise ember_command_crash("busy") }

      expect { nx.build }.to nap(60)
      expect(EmberTemplateHost[ember_template_id: template.id, vm_host_id: builder.id]).to be_nil
    end
  end

  describe "#wait_builds" do
    let(:other) { create_ember_host(cpu_signature: template.cpu_signature) }

    before do
      EmberTemplateHost.create(ember_template_id: template.id, vm_host_id: builder.id)
    end

    # Each host's build state, as host/bin/ember template-status reports it.
    def builds(states)
      on_ember_command { |cmd, kw, sshable|
        expect([cmd, kw[:template]]).to eq(["template-status", template.ubid])
        states.fetch(sshable.id)
      }
    end

    def row(host) = EmberTemplateHost[ember_template_id: template.id, vm_host_id: host.id]

    it "makes the template ready as soon as one host has built it" do
      EmberTemplateHost.create(ember_template_id: template.id, vm_host_id: other.id)
      builds(builder.id => {"state" => "ready"}, other.id => {"state" => "building"})

      expect { nx.wait_builds }.to nap(described_class::BUILD_POLL_SECONDS)
      expect(row(builder).state).to eq("ready")
      expect(template.reload.state).to eq("ready")
    end

    it "keeps the template ready when a later host fails" do
      template.update(state: "ready")
      builds(builder.id => {"state" => "failed", "detail" => "guest never quiesced"})

      expect { nx.wait_builds }.to hop("wait")
      expect(row(builder).state).to eq("failed")
      expect(template.reload.state).to eq("ready")
    end

    it "marks the template failed when every host failed, rather than retrying forever" do
      builds(builder.id => {"state" => "failed", "detail" => "guest never quiesced"})
      expect { nx.wait_builds }.to hop("wait")
      expect(template.reload.state).to eq("failed")
    end

    it "keeps the template building while a host still is" do
      EmberTemplateHost.create(ember_template_id: template.id, vm_host_id: other.id, state: "failed")
      builds(builder.id => {"state" => "building"})
      expect { nx.wait_builds }.to nap(described_class::BUILD_POLL_SECONDS)
      expect(template.reload.state).to eq("building")
    end

    it "keeps polling when a host cannot be reached" do
      on_ember_command { raise ember_command_crash("down") }
      expect { nx.wait_builds }.to nap(described_class::BUILD_POLL_SECONDS)
      expect(row(builder).state).to eq("building")
    end
  end

  describe "#wait" do
    before { template.update(state: "ready") }

    it "naps when every peer has a copy" do
      EmberTemplateHost.create(ember_template_id: template.id, vm_host_id: builder.id, state: "ready")
      expect { nx.wait }.to nap(described_class::WAIT_SECONDS)
    end

    it "builds on a host that appeared after the build" do
      builder
      expect { nx.wait }.to hop("build")
    end

    it "naps when the template never built" do
      template.update(state: "failed")
      builder
      expect { nx.wait }.to nap(described_class::WAIT_SECONDS)
    end

    it "retires when asked, without deleting anything" do
      template.incr_retire
      expect { nx.wait }.to hop("wait")
      expect(template.reload.state).to eq("retired")
    end

    it "hops to destroy when asked" do
      template.incr_destroy
      expect { nx.wait }.to hop("destroy")
    end
  end

  describe "#destroy" do
    it "removes the copies and the row" do
      EmberTemplateHost.create(ember_template_id: template.id, vm_host_id: builder.id, state: "ready")
      deleted = []
      on_ember_command { |cmd, kw|
        deleted << [cmd, kw[:template]]
        {"deleted" => true}
      }

      expect { nx.destroy }.to exit({"msg" => "ember template destroyed"})
      expect(deleted).to eq([["delete-template", template.ubid]])
      expect(EmberTemplate[template.id]).to be_nil
    end

    it "carries on when a host will not delete its copy" do
      EmberTemplateHost.create(ember_template_id: template.id, vm_host_id: builder.id, state: "ready")
      on_ember_command { raise ember_command_crash("down") }

      expect { nx.destroy }.to exit({"msg" => "ember template destroyed"})
      expect(EmberTemplate[template.id]).to be_nil
    end

    it "refuses while an ember still uses it" do
      create_ember(ember_template_id: template.id)
      expect { nx.destroy }.to nap(60)
      expect(EmberTemplate[template.id]).not_to be_nil
    end
  end
end
