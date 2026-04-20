# frozen_string_literal: true

RSpec.describe VmGcpResource do
  let(:project) { Project.create(name: "test-vmgcpres-prj") }
  let(:location) {
    Location.create(name: "gcp-us-central1", provider: "gcp", project_id: project.id,
      display_name: "GCP US Central 1", ui_name: "GCP US Central 1", visible: true)
  }
  let(:az) { LocationAz.create(location_id: location.id, az: "a") }
  let(:vm) {
    Vm.create(
      unix_user: "ubi", public_key: "ssh-ed25519 key",
      name: "vmgcpres-vm",
      family: "c4a-standard", cores: 0, vcpus: 8,
      memory_gib: 32, arch: "arm64",
      location_id: location.id, project_id: project.id,
      boot_image: "projects/ubuntu-os-cloud/global/images/family/ubuntu-2404-lts-amd64",
      display_state: "creating", ip4_enabled: false, created_at: Time.now,
    )
  }

  it "supports create, read, and cascades destroy from vm" do
    res = described_class.create_with_id(vm, location_az_id: az.id)
    expect(described_class[vm.id]).to eq(res)
    expect(res.location_az).to eq(az)
    expect(res.vm).to eq(vm)
    expect(vm.vm_gcp_resource).to eq(res)

    vm.destroy
    expect(described_class[vm.id]).to be_nil
  end
end
