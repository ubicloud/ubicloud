# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe VictoriaMetricsServer do
  subject(:vms) {
    vm = create_vm(ephemeral_net6: "fdfa:b5aa:14a3:4a3d::/64")
    vmr = VictoriaMetricsResource.create_with_id(
      location_id: Location::HETZNER_FSN1_ID,
      name: "victoria-metrics-cluster",
      admin_user: "vm-admin",
      admin_password: "dummy-password",
      root_cert_1: "dummy-root-cert-1",
      root_cert_2: "dummy-root-cert-2",
      target_vm_size: "standard-2",
      target_storage_size_gib: 128,
      project_id: vm.project_id
    )

    described_class.create_with_id(
      victoria_metrics_resource_id: vmr.id,
      vm_id: vm.id,
      cert: "cert",
      cert_key: "cert-key"
    )
  }

  it "returns public ipv6 address properly" do
    expect(vms.public_ipv6_address).to eq("fdfa:b5aa:14a3:4a3d::2")
  end

  it "returns victoria metrics resource properly" do
    expect(vms.resource.name).to eq("victoria-metrics-cluster")
  end

  it "redacts the cert column" do
    expect(described_class.redacted_columns).to include(:cert)
  end
end
