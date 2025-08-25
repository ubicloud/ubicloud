# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Postgres::UpgradePostgresResource do
  subject(:nx) { described_class.new(st) }

  let(:st) {
    Strand.new(
      id: "329d16c7-670c-4f64-927f-67c3fef180b1",
      stack: [{"candidate_server_id" => "6aea22d4-09ea-4ef3-b2e9-2868cc54a2fe",
               "new_timeline_id" => "c3b94c9a-c664-4b94-96ad-0df6047df115"}]
    )
  }

  let(:candidate_server) {
    instance_double(PostgresServer,
      id: "6aea22d4-09ea-4ef3-b2e9-2868cc54a2fe",
      strand: instance_double(Strand, label: "wait"),
      synchronization_status: "ready",
      vm: instance_double(
        Vm,
        id: "1c7d59ee-8d46-8374-9553-6144490ecec5",
        sshable: sshable,
        ephemeral_net4: "1.1.1.1",
        private_subnets: [instance_double(PrivateSubnet)]
      ))
  }

  let(:sshable) { instance_double(Sshable) }

  let(:new_timeline) { instance_double(PostgresTimeline, id: "c3b94c9a-c664-4b94-96ad-0df6047df115") }

  let(:primary_server) {
    instance_double(PostgresServer,
      id: "fe8ffa37-1f58-47e1-9f49-15af06cec185",
      strand: instance_double(Strand, label: "wait"),
      synchronization_status: "ready")
  }

  let(:postgres_resource) {
    instance_double(PostgresResource,
      id: "postgres_resource_id",
      servers: [primary_server, candidate_server],
      timeline: instance_double(PostgresTimeline, id: "timeline-id"),
      location: instance_double(Location, aws?: false),
      representative_server: primary_server,
      desired_version: "17")
  }

  before do
    allow(nx).to receive_messages(postgres_resource: postgres_resource)
    allow(PostgresServer).to receive(:[]).with(candidate_server.id).and_return(candidate_server)
    allow(PostgresServer).to receive(:[]).with(primary_server.id).and_return(primary_server)
    allow(PostgresTimeline).to receive(:[]).with(new_timeline.id).and_return(new_timeline)
  end

  describe "#start" do
    it "registers a deadline" do
      expect(nx).to receive(:register_deadline).with("finish_upgrade", 2 * 60 * 60)
      expect { nx.start }.to hop("wait_for_standby")
    end
  end

  describe "#wait_for_standby" do
    it "waits for the standby to be ready" do
      expect(candidate_server).to receive(:strand).and_return(instance_double(Strand, label: "start"))
      expect { nx.wait_for_standby }.to nap(5)
    end

    it "hops to wait_for_maintenance_window when the standby is ready" do
      expect(candidate_server).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
      expect { nx.wait_for_standby }.to hop("wait_for_maintenance_window")
    end
  end

  describe "#wait_for_maintenance_window" do
    it "waits for the maintenance window to be open" do
      expect(postgres_resource).to receive(:in_maintenance_window?).and_return(false)
      expect { nx.wait_for_maintenance_window }.to nap(10 * 60)
    end

    it "hops to wait_fence_primary if primary is fenced" do
      expect(postgres_resource).to receive(:in_maintenance_window?).and_return(true)
      expect(primary_server).to receive(:incr_fence)
      expect { nx.wait_for_maintenance_window }.to hop("wait_fence_primary")
    end
  end

  describe "#wait_fence_primary" do
    it "waits for the primary to be fenced" do
      expect(primary_server).to receive(:strand).and_return(instance_double(Strand, label: "start"))
      expect { nx.wait_fence_primary }.to nap(5)
    end

    it "hops to upgrade_standby if primary is fenced" do
      expect(primary_server).to receive(:strand).and_return(instance_double(Strand, label: "wait_fence"))
      expect { nx.wait_fence_primary }.to hop("upgrade_standby")
    end
  end

  describe "#upgrade_standby" do
    it "hops to update_metadata if the upgrade succeeds" do
      expect(sshable).to receive(:d_check).with("upgrade_postgres").and_return("Succeeded")
      expect(sshable).to receive(:d_clean).with("upgrade_postgres")
      expect { nx.upgrade_standby }.to hop("update_metadata")
    end

    it "hops to upgrade_failed if the upgrade fails" do
      expect(sshable).to receive(:d_check).with("upgrade_postgres").and_return("Failed")
      expect { nx.upgrade_standby }.to hop("upgrade_failed")
    end

    it "starts the upgrade if it is not started" do
      expect(sshable).to receive(:d_check).with("upgrade_postgres").and_return("NotStarted")
      expect(sshable).to receive(:d_run).with("upgrade_postgres", "sudo", "postgres/bin/upgrade", "17")
      expect { nx.upgrade_standby }.to nap(5)
    end

    it "naps for 5 seconds if the upgrade is unknown" do
      expect(sshable).to receive(:d_check).with("upgrade_postgres").and_return("Unknown")
      expect { nx.upgrade_standby }.to nap(5)
    end
  end

  describe "#update_metadata" do
    it "switches the candidate to a new timeline" do
      expect(candidate_server).to receive(:update).with(timeline_id: "c3b94c9a-c664-4b94-96ad-0df6047df115", version: "17")
      expect(postgres_resource).to receive(:update).with(timeline: new_timeline, version: "17")
      expect(candidate_server).to receive_messages(incr_refresh_walg_credentials: nil, incr_configure: nil, incr_restart: nil, incr_unplanned_take_over: nil)
      expect { nx.update_metadata }.to hop("wait_takeover")
    end
  end

  describe "#wait_takeover" do
    it "hops to prune_old_servers when the takeover is done" do
      expect(candidate_server).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
      expect(postgres_resource).to receive(:representative_server).and_return(candidate_server)
      expect { nx.wait_takeover }.to hop("prune_old_servers")
    end

    it "waits for the takeover to be done" do
      expect(candidate_server).to receive(:strand).and_return(instance_double(Strand, label: "prepare_for_unplanned_take_over"))
      expect { nx.wait_takeover }.to nap(5)
    end
  end

  describe "#prune_old_servers" do
    it "prunes old servers" do
      expect(candidate_server).to receive(:version).and_return("17")
      expect(primary_server).to receive(:version).and_return("16")
      expect(primary_server).to receive(:incr_destroy)
      expect { nx.prune_old_servers }.to hop("finish_upgrade")
    end
  end

  describe "#finish_upgrade" do
    it "finishes the upgrade" do
      expect { nx.finish_upgrade }.to exit({"msg" => "upgrade prog finished"})
    end
  end

  describe "#upgrade_failed" do
    it "finishes the upgrade" do
      expect(sshable).to receive(:cmd).with("sudo journalctl -u upgrade_postgres").and_return("log1\nlog2\nlog3")
      expect(candidate_server).to receive(:incr_destroy)
      expect(new_timeline).to receive(:incr_destroy)
      expect(primary_server).to receive(:strand).and_return(instance_double(Strand, label: "wait_fence"))
      expect(primary_server).to receive(:incr_unfence)
      expect { nx.upgrade_failed }.to nap(6 * 60 * 60)
    end

    it "naps for 6 hours when the candidate server is nil" do
      expect(nx).to receive(:candidate_server).and_return(nil)
      expect(new_timeline).to receive(:incr_destroy)
      expect { nx.upgrade_failed }.to nap(6 * 60 * 60)
    end

    it "naps for 6 hours when no candidate server or timeline is available" do
      expect(nx).to receive(:candidate_server).and_return(nil)
      expect(nx).to receive(:new_timeline).and_return(nil)
      expect { nx.upgrade_failed }.to nap(6 * 60 * 60)
    end
  end

  describe "#candidate_server" do
    it "returns the candidate server" do
      expect(nx.candidate_server).to eq(candidate_server)
    end
  end

  describe "#new_timeline" do
    it "returns the new timeline" do
      expect(nx.new_timeline).to eq(new_timeline)
    end
  end
end
