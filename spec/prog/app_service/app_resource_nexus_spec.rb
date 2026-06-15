# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::AppService::AppResourceNexus do
  subject(:nx) { described_class.new(st) }

  let(:user_project) { Project.create_with_id(Project.generate_uuid, name: "user-proj") }
  let(:app_project) { Project.create_with_id(Project.generate_uuid, name: "app-svc") }

  let(:st) {
    described_class.assemble(
      project_id: user_project.id,
      location_id: Location::HETZNER_FSN1_ID,
      name: "test-app",
      repo_url: "https://github.com/owner/repo",
      branch: "main",
    )
  }

  let(:app_resource) { nx.app_resource }

  before do
    allow(Config).to receive_messages(app_service_project_id: app_project.id, control_plane_outbound_cidrs: ["172.16.0.0/16"])
  end

  describe ".assemble" do
    it "creates the resource, service-project networking, secret store, server, and strand" do
      expect(st).to be_a(Strand)
      expect(st.label).to eq("start")

      expect(app_resource.project_id).to eq(user_project.id)
      expect(app_resource.private_subnet.project_id).to eq(app_project.id)
      expect(app_resource.secret_store.project_id).to eq(app_project.id)
      expect(app_resource.servers.count).to eq(1)

      expect(app_resource.load_balancer).not_to be_nil
      expect(app_resource.load_balancer.project_id).to eq(app_project.id)
      expect(app_resource.load_balancer.dst_port).to eq(8080)

      expect(app_resource.processes.map(&:process_type)).to eq(["web"])
      expect(app_resource.processes.first.replica_count).to eq(1)
      expect(app_resource.processes.first.vm_size).to eq("hobby-1")

      firewall = app_resource.private_subnet.firewalls_dataset.first(name: "#{app_resource.ubid}-firewall")
      ports = firewall.firewall_rules.map { it.port_range.begin }
      expect(ports).to include(22, 8080)
    end
  end

  describe "#start" do
    it "sets up log aggregation (no-op without Parseable) and hops to wait_servers" do
      expect { nx.start }.to hop("wait_servers")
    end
  end

  describe "#wait_servers" do
    it "naps while servers are not all in wait" do
      expect { nx.wait_servers }.to nap(10)
    end

    it "hops to wait once all servers are waiting" do
      app_resource.servers.each { it.strand.update(label: "wait") }
      expect { nx.wait_servers }.to hop("wait")
    end
  end

  describe "#wait" do
    it "naps for approximately one month" do
      expect { nx.wait }.to nap(60 * 60 * 24 * 30)
    end

    it "hops to destroy when the destroy semaphore is set" do
      nx.incr_destroy
      expect { nx.wait }.to hop("destroy")
    end

    it "hops to start_deploy when the deploy semaphore is set" do
      nx.incr_deploy
      expect { nx.wait }.to hop("start_deploy")
    end
  end

  describe "#start_deploy" do
    it "marks the latest deployment building, signals servers, and hops to wait_deploy" do
      deployment = AppDeployment.create(app_resource_id: app_resource.id, version: 1, status: "pending")

      expect { nx.start_deploy }.to hop("wait_deploy")

      expect(deployment.reload.status).to eq("building")
      server_ids = app_resource.servers.map(&:id)
      expect(Semaphore.where(strand_id: server_ids, name: "deploy").count).to eq(server_ids.count)
    end
  end

  describe "#wait_deploy" do
    let(:deployment) { AppDeployment.create(app_resource_id: app_resource.id, version: 1, status: "building") }

    it "gives up (hops to wait) when the deployment failed" do
      deployment.update(status: "failed")
      expect { nx.wait_deploy }.to hop("wait")
    end

    it "naps while servers have not converged on the target deployment" do
      deployment
      expect { nx.wait_deploy }.to nap(10)
    end

    it "activates the deployment and supersedes the prior one once servers converge" do
      prior = AppDeployment.create(app_resource_id: app_resource.id, version: 0, status: "active")
      app_resource.update(current_deployment_id: prior.id)
      app_resource.servers.each { it.update(current_deployment_id: deployment.id) }

      expect { nx.wait_deploy }.to hop("wait")

      expect(deployment.reload.status).to eq("active")
      expect(prior.reload.status).to eq("superseded")
      expect(app_resource.reload.current_deployment_id).to eq(deployment.id)
    end
  end

  describe "#converge" do
    it "scales a process up by assembling new servers" do
      process = app_resource.processes.first
      process.update(replica_count: 3)

      expect { nx.converge }.to hop("wait")

      expect(process.servers_dataset.count).to eq(3)
    end

    it "scales a process down by destroying excess servers" do
      process = app_resource.processes.first
      2.times { Prog::AppService::AppServerNexus.assemble(process) }
      expect(process.servers_dataset.count).to eq(3)

      expect { nx.converge }.to hop("wait")

      expect(Semaphore.where(name: "destroy", strand_id: process.servers_dataset.select(:id)).count).to eq(2)
    end

    it "does nothing when the formation already matches" do
      expect { nx.converge }.to hop("wait")
      expect(app_resource.processes.first.servers_dataset.count).to eq(1)
    end
  end

  describe "#destroy" do
    it "destroys the firewall, increments destroy on the load balancer, subnet, and servers, and hops" do
      subnet = app_resource.private_subnet
      lb = app_resource.load_balancer
      server_ids = app_resource.servers.map(&:id)

      expect { nx.destroy }.to hop("wait_servers_destroyed")

      expect(subnet.firewalls_dataset.first(name: "#{app_resource.ubid}-firewall")).to be_nil
      expect(Semaphore.where(strand_id: lb.id, name: "destroy").count).to eq(1)
      expect(Semaphore.where(strand_id: subnet.id, name: "destroy").count).to eq(1)
      expect(Semaphore.where(strand_id: server_ids, name: "destroy").count).to eq(server_ids.count)
    end
  end

  describe "#wait_servers_destroyed" do
    it "naps while servers remain" do
      expect { nx.wait_servers_destroyed }.to nap(10)
    end

    it "removes secret store grants, destroys the secret store and resource, and pops" do
      secret_store = app_resource.secret_store
      resource_id = app_resource.id
      expect(AccessControlEntry.where(object_id: secret_store.id).count).to eq(1)

      app_resource.servers.each(&:destroy)

      expect { nx.wait_servers_destroyed }.to exit({"msg" => "app resource destroyed"})

      expect(AccessControlEntry.where(object_id: secret_store.id).count).to eq(0)
      expect(SecretStore[secret_store.id]).to be_nil
      expect(AppResource[resource_id]).to be_nil
    end
  end
end
