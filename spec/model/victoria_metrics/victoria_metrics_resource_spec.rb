# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe VictoriaMetricsResource do
  subject(:vmr) {
    described_class.create_with_id(
      name: "victoria-metrics-name",
      admin_user: "victoria-admin",
      admin_password: "dummy-password",
      target_vm_size: "standard-2",
      target_storage_size_gib: 128,
      root_cert_1: "dummy-root-cert-1",
      root_cert_2: "dummy-root-cert-2",
      project_id: project.id,
      location_id: location.id
    )
  }

  let(:project) { Project.create_with_id(name: "default") }
  let(:victoria_metrics_project) { Project.create_with_id(name: "victoria-metrics") }
  let(:location) {
    Location.create(
      name: "us-west-2",
      display_name: "aws-us-west-2",
      ui_name: "aws-us-west-2",
      visible: true,
      provider: "aws",
      project_id: victoria_metrics_project.id
    )
  }

  it "returns hostname properly" do
    allow(Config).to receive(:victoria_metrics_host_name).and_return("victoria.ubicloud.com")
    expect(vmr.hostname).to eq("victoria-metrics-name.victoria.ubicloud.com")
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
  end

  it "has encrypted columns" do
    expect(vmr).to respond_to(:admin_password)
    expect(vmr).to respond_to(:root_cert_key_1)
    expect(vmr).to respond_to(:root_cert_key_2)
  end
end
