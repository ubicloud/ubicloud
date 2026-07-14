# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe VictoriaMetricsResource do
  subject(:vmr) {
    described_class.create(
      name: "victoria-metrics-name",
      admin_user: "victoria-admin",
      admin_password: "dummy-password",
      target_vm_size: "standard-2",
      target_storage_size_gib: 128,
      root_cert_1: "dummy-root-cert-1",
      root_cert_2: "dummy-root-cert-2",
      project_id: project.id,
      location_id: location.id,
    )
  }

  let(:project) { Project.create(name: "default") }
  let(:victoria_metrics_project) { Project.create(name: "victoria-metrics") }
  let(:location) {
    Location.create(
      name: "us-west-2",
      display_name: "aws-us-west-2",
      ui_name: "aws-us-west-2",
      visible: true,
      provider: "aws",
      project_id: victoria_metrics_project.id,
    )
  }

  it "can have endpoint overridden by Config.victoria_metrics_endpoint_override" do
    allow(Config).to receive(:victoria_metrics_endpoint_override).and_return("http://victoria.endpoint")
    client = instance_double(VictoriaMetrics::Client)
    expect(VictoriaMetrics::Client).to receive(:new).with(endpoint: Config.victoria_metrics_endpoint_override).and_return(client)
    expect(described_class.client_for_project(victoria_metrics_project.id)).to be(client)
  end

  it "returns hostname properly" do
    allow(Config).to receive(:victoria_metrics_host_name).and_return("victoria.ubicloud.com")
    expect(vmr.hostname).to eq("victoria-metrics-name.victoria.ubicloud.com")
  end

  describe "#client_for_project" do
    it "returns nil when the resource has no representative server outside development" do
      vmr # ensure the resource exists for the lookup
      expect(described_class.client_for_project(project.id)).to be_nil
    end

    it "returns the representative server's client unwrapped when there is only one server" do
      vm = create_vm
      VictoriaMetricsServer.create(victoria_metrics_resource_id: vmr.id, vm_id: vm.id, is_representative: true)
      client = instance_double(VictoriaMetrics::Client)
      expect(VictoriaMetrics::Client).to receive(:new).and_return(client)
      expect(described_class.client_for_project(project.id)).to be(client)
    end

    it "wraps the client in a TeeClient pointed at every non-representative server's IPv4 when there are multiple servers" do
      representative_vm = create_vm
      VictoriaMetricsServer.create(victoria_metrics_resource_id: vmr.id, vm_id: representative_vm.id, is_representative: true)
      secondary_vm = create_vm
      VictoriaMetricsServer.create(victoria_metrics_resource_id: vmr.id, vm_id: secondary_vm.id, is_representative: false)

      primary_client = instance_double(VictoriaMetrics::Client)
      secondary_client = instance_double(VictoriaMetrics::Client)
      expect(VictoriaMetrics::Client).to receive(:new).with(hash_including(verify_host: nil)).and_return(primary_client)
      expect(VictoriaMetrics::Client).to receive(:new).with(hash_including(
        endpoint: a_string_matching(%r{\Ahttps://[^\[\]]*:8427\z}),
        ssl_ca_data: vmr.root_certs,
        verify_host: vmr.hostname,
        username: vmr.admin_user,
        password: vmr.admin_password,
      )).and_return(secondary_client)

      tee_client = described_class.client_for_project(project.id)
      expect(tee_client).to be_a(VictoriaMetrics::TeeClient)
      expect(tee_client.__getobj__).to be(primary_client)
      expect(tee_client.instance_variable_get(:@secondaries)).to eq([secondary_client])
    end
  end

  describe "#dns_zone" do
    it "returns the DnsZone matching victoria_metrics_service_project_id and victoria_metrics_host_name" do
      dns_zone = DnsZone.create(project_id: vmr.project_id, name: "victoria.example.com")
      expect(Config).to receive_messages(victoria_metrics_service_project_id: vmr.project_id, victoria_metrics_host_name: "victoria.example.com")
      expect(vmr.dns_zone).to eq(dns_zone)
    end

    it "returns nil when no matching DnsZone exists" do
      expect(Config).to receive_messages(victoria_metrics_service_project_id: vmr.project_id, victoria_metrics_host_name: "victoria.example.com")
      expect(vmr.dns_zone).to be_nil
    end
  end

  it "returns root_certs properly when both certificates are present" do
    expect(vmr.root_certs).to eq("dummy-root-cert-1\ndummy-root-cert-2")
  end

  it "returns nil for root_certs when certificates are missing" do
    vmr.update(root_cert_1: nil, root_cert_2: nil)
    expect(vmr.root_certs).to be_nil
  end

  it "returns nil for root_certs when only one certificate is present" do
    vmr.update(root_cert_1: nil)
    expect(vmr.root_certs).to be_nil
  end

  it "includes encrypted columns in redacted_columns" do
    expect(described_class.redacted_columns).to include(:admin_password, :root_cert_1, :root_cert_2)
  end

  it "has proper associations" do
    expect(vmr).to respond_to(:strand)
    expect(vmr).to respond_to(:project)
    expect(vmr).to respond_to(:location)
    expect(vmr).to respond_to(:servers)
    expect(vmr).to respond_to(:representative_server)
  end

  describe "#representative_server" do
    it "returns the server with is_representative set" do
      vm = create_vm
      server = VictoriaMetricsServer.create(victoria_metrics_resource_id: vmr.id, vm_id: vm.id, is_representative: true)
      expect(vmr.reload.representative_server).to eq(server)
    end

    it "returns nil when no server is representative" do
      vm = create_vm
      VictoriaMetricsServer.create(victoria_metrics_resource_id: vmr.id, vm_id: vm.id, is_representative: false)
      expect(vmr.reload.representative_server).to be_nil
    end
  end

  it "has encrypted columns" do
    expect(vmr).to respond_to(:admin_password)
    expect(vmr).to respond_to(:root_cert_key_1)
    expect(vmr).to respond_to(:root_cert_key_2)
  end
end
