# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe DetachableVolume do
  let(:volume) { create_detachable_volume }

  it "generates dv-prefixed ubids" do
    expect(described_class.generate_ubid.to_s).to start_with("dv")
  end

  it "starts out with no data anywhere" do
    expect(volume.vm_host_id).to be_nil
  end

  describe "#record_host" do
    let(:host) { create_vm_host }

    it "records the host that holds its data" do
      volume.record_host(host:)
      expect(volume.reload.vm_host_id).to eq(host.id)
    end
  end

  describe "#key_material" do
    it "hands out the KEK and the wrapped data key" do
      expect(volume.key_material).to eq({"kek" => volume.key_encryption_key_1.key, "wrapped_xts" => volume.wrapped_xts})
    end
  end

  describe "#stripe_source_for" do
    let(:host) { create_vm_host }

    it "seeds a new volume from the local image" do
      expect(volume.stripe_source_for(host)).to eq({"type" => "new", "image" => "ubuntu-noble"})
    end

    it "uses the local copy when the data is already on this host" do
      volume.update(vm_host_id: host.id)
      expect(volume.stripe_source_for(host)).to eq({"type" => "local"})
    end

    it "does not claim local data on a different host" do
      volume.update(vm_host_id: host.id)
      expect(volume.stripe_source_for(create_vm_host)).to be_nil
    end
  end
end
