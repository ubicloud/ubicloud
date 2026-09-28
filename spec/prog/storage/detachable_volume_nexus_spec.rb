# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Storage::DetachableVolumeNexus do
  subject(:nx) { described_class.new(volume.strand) }

  let(:host) { create_vm_host }
  let(:volume) { create_detachable_volume(vm_host_id: host.id).reload }

  def expect_host_command(command, result = {})
    expect(nx.detachable_volume.vm_host.sshable).to receive(:_cmd)
      .with("sudo host/bin/detachable-volume #{command} #{volume.ubid}").and_return(JSON.generate(result))
  end

  def host_failure
    Sshable::SshError.new("sudo host/bin/detachable-volume", "", "down", 1, nil)
  end

  describe ".assemble" do
    it "creates a new volume with keys of its own and a strand" do
      project = Project.create(name: "volume-owner")
      v = described_class.assemble(project_id: project.id, location_id: Location::HETZNER_FSN1_ID,
        size_gib: 4, source_image: "seed-image")
      expect(v.size_gib).to eq(4)
      expect(v.vm_host_id).to be_nil
      expect(v.key_encryption_key_1.auth_data).to eq(v.ubid)
      expect(v.wrapped_xts).not_to be_nil
      expect(v.strand.label).to eq("wait")
    end
  end

  describe "#wait" do
    it "naps when there is nothing to do" do
      expect { nx.wait }.to nap(30 * 24 * 60 * 60)
    end

    it "hops to destroy when asked" do
      volume.incr_destroy
      expect { nx.wait }.to hop("destroy")
    end
  end

  describe "#destroy" do
    it "waits for a key rotation to finish" do
      volume.update(key_encryption_key_2_id: StorageKeyEncryptionKey.create_random(auth_data: "k2").id)
      expect { nx.destroy }.to nap(5)
    end

    it "removes the local copy, the row and the keys" do
      kek = volume.key_encryption_key_1
      volume.incr_destroy
      expect_host_command("delete", {"deleted" => true})
      expect { nx.destroy }.to exit({"msg" => "detachable volume destroyed"})
      expect(volume).not_to exist
      expect(kek).not_to exist
    end

    it "leaves a host that cannot be reached to the strand's retries, keeping the row" do
      expect(nx.detachable_volume.vm_host.sshable).to receive(:_cmd).and_raise(host_failure)
      expect { nx.destroy }.to raise_error(Sshable::SshError)
      expect(volume).to exist
    end

    it "does not call the host when there is nothing there" do
      volume.update(vm_host_id: nil)
      expect { nx.destroy }.to exit({"msg" => "detachable volume destroyed"})
      expect(volume).not_to exist
    end
  end
end
