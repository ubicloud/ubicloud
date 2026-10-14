# frozen_string_literal: true

RSpec.describe Simulation do
  let(:service_project_id) { Project.generate_uuid }

  before do
    allow(Config).to receive_messages(simulation_mode: true, github_runner_service_project_id: service_project_id)
  end

  describe ".seed" do
    it "creates the projects and allocatable hosts" do
      hosts = described_class.seed(host_count: 2, total_cores: 8, total_hugepages_1g: 50)

      expect(Project[service_project_id]).not_to be_nil
      customer = described_class.customer_project
      expect(customer.billing_info).not_to be_nil
      expect(customer.effective_quota_value("GithubRunnerVCpu")).to eq(1_000_000)

      host = hosts.last
      expect(host).to have_attributes(location_id: Location::GITHUB_RUNNERS_ID, allocation_state: "accepting", total_cpus: 16, used_cores: 1, data_center: "SIM-DC1")
      expect(host.cpus_dataset.count).to eq(16)
      expect(host.storage_devices.map(&:available_storage_gib)).to eq([3500, 3500])
      expect(host.vhost_block_backends.count).to eq(1)
      expect(host.boot_images_dataset.select_map(:name)).to include("github-ubuntu-2404")
      expect(host.ip4_random_vm_network.first.to_s).to start_with("100.64.1.")
    end

    it "adds hosts to an already seeded simulation" do
      described_class.seed(host_count: 1)
      hosts = described_class.seed(host_count: 1)

      expect(Project.where(name: described_class::CUSTOMER_PROJECT_NAME).count).to eq(1)
      expect(hosts.first.data_center).to eq("SIM-DC1")
      expect(VmHost.count).to eq(2)
    end

    it "fails outside simulation mode" do
      allow(Config).to receive(:simulation_mode).and_return(false)
      expect { described_class.seed(host_count: 1) }.to raise_error RuntimeError, "Simulation mode is not enabled"
    end

    it "fails without the runner service project" do
      allow(Config).to receive(:github_runner_service_project_id).and_return(nil)
      expect { described_class.seed(host_count: 1) }.to raise_error RuntimeError, "GITHUB_RUNNER_SERVICE_PROJECT_ID is not set"
    end
  end

  describe ".find_or_register_installation" do
    it "fails if the simulation is not seeded" do
      expect { described_class.find_or_register_installation(1, nil) }.to raise_error RuntimeError, /not seeded/
    end

    it "registers an installation once" do
      described_class.seed(host_count: 0)
      installation = described_class.find_or_register_installation(1, "acme")

      expect(installation).to have_attributes(installation_id: 1, name: "acme", project_id: described_class.customer_project.id)
      expect(described_class.find_or_register_installation(1, "other").id).to eq(installation.id)
      expect(described_class.find_or_register_installation(2, nil).name).to eq("simulated-2")
    end
  end
end
