# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Prog::Postgres::Restart do
  subject(:nx) { described_class.new(st) }

  let(:project) { Project.create(name: "test-project") }
  let(:postgres_resource) { create_postgres_resource(location_id:) }
  let(:postgres_timeline) { create_postgres_timeline(location_id:) }
  let(:postgres_server) { create_postgres_server(resource: postgres_resource, timeline: postgres_timeline) }
  let(:st) { postgres_server.strand }
  let(:server) { nx.postgres_server }
  let(:sshable) { server.vm.sshable }
  let(:resource) { postgres_resource }
  let(:service_project) { Project.create(name: "postgres-service-project") }
  let(:location_id) { Location::HETZNER_FSN1_ID }

  let(:private_subnet) {
    PrivateSubnet.create(
      name: "pg-subnet", project_id: project.id, location_id:,
      net4: "172.0.0.0/26", net6: "fdfa:b5aa:14a3:4a3d::/64"
    )
  }

  describe "#start" do
    it "pops if configure is set so parent can handle it" do
      nx.incr_configure
      expect { nx.start }.to exit({"msg" => "restart deferred due to pending configure"})
      expect(nx.configure_set?).to be true
    end

    it "sets deadline and hops to restart" do
      expect { nx.start }.to hop("restart")
      expect(nx.strand.stack.first["deadline_target"]).to be_nil
      expect(nx.strand.stack.first["deadline_at"]).to be_within(5).of(Time.now + 5 * 60)
    end
  end

  describe "#restart" do
    it "runs restart command when not started" do
      expect(sshable).to receive(:d_check).with("postgres_restart").and_return("NotStarted")
      expect(sshable).to receive(:d_run).with("postgres_restart", "sudo", "postgres/bin/restart", "16")
      expect { nx.restart }.to nap(5)
    end

    it "naps when restart is in progress" do
      expect(sshable).to receive(:d_check).with("postgres_restart").and_return("InProgress")
      expect { nx.restart }.to nap(5)
    end

    it "cleans and pops when restart succeeds" do
      expect(sshable).to receive(:d_check).with("postgres_restart").and_return("Succeeded")
      expect(sshable).to receive(:d_clean).with("postgres_restart")
      expect { nx.restart }.to exit({"msg" => "postgres server is restarted"})
    end

    it "cleans and naps when restart fails" do
      expect(sshable).to receive(:d_check).with("postgres_restart").and_return("Failed")
      expect(sshable).to receive(:d_clean).with("postgres_restart")
      expect { nx.restart }.to nap(5)
    end
  end
end
