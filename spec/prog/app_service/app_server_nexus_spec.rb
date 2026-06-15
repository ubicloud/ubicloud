# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::AppService::AppServerNexus do
  subject(:nx) { described_class.new(st) }

  let(:app_project) { Project.create_with_id(Project.generate_uuid, name: "app-svc") }
  let(:subnet) { Prog::Vnet::SubnetNexus.assemble(app_project.id, name: "test-app-subnet", location_id: Location::HETZNER_FSN1_ID) }
  let(:secret_store) { SecretStore.create(project_id: app_project.id, name: "test-secrets") }

  let(:app_resource) {
    AppResource.create(
      project_id: app_project.id,
      location_id: Location::HETZNER_FSN1_ID,
      name: "test-app",
      repo_url: "https://github.com/owner/repo",
      branch: "main",
      target_vm_size: "standard-2",
      private_subnet_id: subnet.id,
      secret_store_id: secret_store.id,
    )
  }

  let(:st) { described_class.assemble(app_resource) }
  let(:app_server) { nx.app_server }
  let(:sshable) { nx.vm.sshable }

  before do
    allow(Config).to receive(:app_service_project_id).and_return(app_project.id)
  end

  describe ".assemble" do
    it "creates a server, vm, managed-identity grant, and strand" do
      expect(st).to be_a(Strand)
      expect(st.label).to eq("start")
      expect(app_server.app_resource_id).to eq(app_resource.id)
      expect(app_server.vm).not_to be_nil

      ace = AccessControlEntry.where(object_id: secret_store.id, subject_id: app_server.vm_id).first
      expect(ace).not_to be_nil
      expect(ace.action_id).to eq(ActionType::NAME_MAP["SecretStore:view"])
    end
  end

  describe "#start" do
    it "naps if the vm is not yet ready" do
      nx.vm.strand.update(label: "start")
      expect { nx.start }.to nap(5)
    end

    it "hops to bootstrap_rhizome when the vm is ready" do
      nx.vm.strand.update(label: "wait")
      expect { nx.start }.to hop("bootstrap_rhizome")
    end
  end

  describe "#bootstrap_rhizome" do
    it "buds BootstrapRhizome and hops to wait_bootstrap_rhizome" do
      expect { nx.bootstrap_rhizome }.to hop("wait_bootstrap_rhizome")

      child = nx.strand.children.first
      expect(child.prog).to eq("BootstrapRhizome")
      expect(child.stack.first).to eq({"target_folder" => "app_service", "subject_id" => nx.vm.id, "user" => "ubi"})
    end
  end

  describe "#wait_bootstrap_rhizome" do
    it "naps while bootstrap is not complete" do
      Strand.create(parent_id: st.id, prog: "BootstrapRhizome", label: "start", stack: [{}], lease: Time.now + 10)
      expect { nx.wait_bootstrap_rhizome }.to nap(120)
    end

    it "hops to install_dependencies when bootstrap is done" do
      Strand.create(parent_id: st.id, prog: "BootstrapRhizome", label: "wait", stack: [{}], exitval: {"msg" => "rhizome installed"})
      expect { nx.wait_bootstrap_rhizome }.to hop("install_dependencies")
    end
  end

  describe "#install_dependencies" do
    it "starts the install when NotStarted" do
      expect(sshable).to receive(:d_check).with("install_app_service_deps").and_return("NotStarted")
      expect(sshable).to receive(:d_run).with("install_app_service_deps", "/home/ubi/app_service/bin/install")
      expect { nx.install_dependencies }.to nap(5)
    end

    it "naps while the install is in progress" do
      expect(sshable).to receive(:d_check).with("install_app_service_deps").and_return("InProgress")
      expect { nx.install_dependencies }.to nap(5)
    end

    it "hops to wait when the install succeeds" do
      expect(sshable).to receive(:d_check).with("install_app_service_deps").and_return("Succeeded")
      expect(sshable).to receive(:d_clean).with("install_app_service_deps")
      expect { nx.install_dependencies }.to hop("wait")
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

    it "hops to deploy when the deploy semaphore is set" do
      nx.incr_deploy
      expect { nx.wait }.to hop("deploy")
    end
  end

  describe "#deploy" do
    let(:deployment) { AppDeployment.create(app_resource_id: app_resource.id, version: 1, status: "building") }

    it "resolves and pins the commit, then starts the build when NotStarted" do
      deployment
      expect(sshable).to receive(:d_check).with("deploy_app").and_return("NotStarted")
      expect(sshable).to receive(:cmd).with("git ls-remote :repo_url :branch", repo_url: app_resource.repo_url, branch: app_resource.branch).and_return("abc123\trefs/heads/main\n")
      expect(sshable).to receive(:d_run).with("deploy_app", "/home/ubi/app_service/bin/deploy", app_resource.repo_url, app_resource.branch, "abc123", app_resource.secret_store.ubid)
      expect { nx.deploy }.to nap(5)
      expect(deployment.reload.commit_sha).to eq("abc123")
    end

    it "does not re-resolve the commit when it is already pinned" do
      deployment.update(commit_sha: "pinned1")
      expect(sshable).to receive(:d_check).with("deploy_app").and_return("NotStarted")
      expect(sshable).not_to receive(:cmd)
      expect(sshable).to receive(:d_run).with("deploy_app", "/home/ubi/app_service/bin/deploy", app_resource.repo_url, app_resource.branch, "pinned1", app_resource.secret_store.ubid)
      expect { nx.deploy }.to nap(5)
    end

    it "naps while the build is in progress" do
      deployment
      expect(sshable).to receive(:d_check).with("deploy_app").and_return("InProgress")
      expect { nx.deploy }.to nap(5)
    end

    it "records the deployment on the server and returns to wait on success" do
      deployment
      expect(sshable).to receive(:d_check).with("deploy_app").and_return("Succeeded")
      expect(sshable).to receive(:d_clean).with("deploy_app")
      expect { nx.deploy }.to hop("wait")
      expect(app_server.reload.current_deployment_id).to eq(deployment.id)
    end

    it "marks the deployment failed on build failure" do
      deployment
      expect(sshable).to receive(:d_check).with("deploy_app").and_return("Failed")
      expect(sshable).to receive(:d_clean).with("deploy_app")
      expect { nx.deploy }.to hop("wait")
      expect(deployment.reload.status).to eq("failed")
    end
  end

  describe "#destroy" do
    it "increments destroy on children and hops to wait_children_destroyed" do
      child = Strand.create(prog: "BootstrapRhizome", label: "start", parent_id: nx.strand.id)
      expect { nx.destroy }.to hop("wait_children_destroyed")
      expect(Semaphore.where(name: "destroy").select_order_map(:strand_id)).to eq [child.id]
    end
  end

  describe "#wait_children_destroyed" do
    it "naps while children remain" do
      Strand.create(prog: "BootstrapRhizome", label: "start", parent_id: nx.strand.id)
      expect { nx.wait_children_destroyed }.to nap(5)
    end

    it "destroys the vm and server when all children are reaped" do
      vm_id = nx.vm.id
      server_id = app_server.id
      expect { nx.wait_children_destroyed }.to exit({"msg" => "app server destroyed"})
      expect(Semaphore.where(strand_id: vm_id, name: "destroy").count).to eq(1)
      expect(AppServer[server_id]).to be_nil
    end
  end
end
