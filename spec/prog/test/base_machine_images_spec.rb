# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Test::BaseMachineImages do
  let(:prog) { described_class.new(described_class.assemble(location_id: Location::HETZNER_FSN1_ID, arch: "x64", base_image_names: ["ubuntu-noble", "ubuntu-resolute"])) }
  let(:strand) { prog.strand }
  let(:metals) {
    %w[ubuntu-resolute ubuntu-noble].freeze.map { |name|
      create_machine_image_version_metal(name:)
    }
  }

  describe ".assemble" do
    it "creates a strand with the correct prog and label" do
      strand = described_class.assemble(location_id: Location::HETZNER_FSN1_ID, arch: "x64", base_image_names: ["ubuntu-noble", "ubuntu-resolute"])
      expect(strand.prog).to eq("Test::BaseMachineImages")
      expect(strand.label).to eq("setup_base_machine_images")
      expect(strand.stack.first["base_image_names"]).to eq(["ubuntu-noble", "ubuntu-resolute"])
    end
  end

  describe "#setup_base_machine_images" do
    it "creates resources and nexuses and hops to wait_setup_base_machine_images" do
      create_vhost_block_backend
      service_project_id = Project.generate_uuid
      expect(Config).to receive_messages(
        machine_images_service_project_id: service_project_id,
        e2e_machine_images_endpoint: "https://example.com",
        e2e_machine_images_bucket: "test-bucket",
        e2e_machine_images_access_key: "test-access-key",
        e2e_machine_images_secret_key: "test-secret-key",
      )
      expect { prog.setup_base_machine_images }.to hop("wait_setup_base_machine_images")
      expect(Project.first(id: service_project_id).name).to eq("machine-images-resources")

      expect(MachineImageStore.where(project_id: service_project_id).all).to contain_exactly(
        have_attributes(
          location_id: Location::HETZNER_FSN1_ID,
          provider: "r2",
          region: "auto",
          endpoint: "https://example.com",
          bucket: "test-bucket",
          access_key: "test-access-key",
          secret_key: "test-secret-key",
        ),
      )

      base_machine_image_version_ids = prog.base_machine_image_version_ids
      expect(base_machine_image_version_ids.size).to eq(2)

      miv_metals = base_machine_image_version_ids.map { |id| MachineImageVersionMetal[id] }
      expect(miv_metals.map(&:status)).to contain_exactly("creating", "creating")

      mi_names = miv_metals.map { |metal| metal.machine_image_version.machine_image.name }
      expect(mi_names).to contain_exactly("ubuntu-noble", "ubuntu-resolute")

      expected_urls = ["ubuntu-noble", "ubuntu-resolute"].map { |name|
        version, = Prog::DownloadBootImage::BOOT_IMAGE_SHA256.dig(name, "x64").max
        Prog::DownloadBootImage.upstream_url(name, version, "x64")
      }
      miv_strands = base_machine_image_version_ids.map { |id| Strand[id] }
      expect(miv_strands.map { |s| s.stack.first["url"] }).to match_array(expected_urls)
    end
  end

  describe "#wait_setup_base_machine_images" do
    before { refresh_frame(prog, new_values: {"base_machine_image_version_ids" => metals.map(&:id)}) }

    it "hops to wait when all machine image versions are ready" do
      MachineImageVersionMetal
        .where(id: prog.base_machine_image_version_ids)
        .update(status: "ready")

      expect { prog.wait_setup_base_machine_images }.to hop("wait")
    end

    it "fails the test if any machine image version has failed" do
      failed_metal = MachineImageVersionMetal[prog.base_machine_image_version_ids.first]
      failed_metal.update(status: "failed")

      expect { prog.wait_setup_base_machine_images }.to hop("failed")
    end

    it "naps if any machine image version is still creating" do
      creating_metal = MachineImageVersionMetal[prog.base_machine_image_version_ids.first]
      creating_metal.update(status: "creating")

      expect { prog.wait_setup_base_machine_images }.to nap(15)
    end
  end

  describe "#wait" do
    before { refresh_frame(prog, new_values: {"base_machine_image_version_ids" => metals.map(&:id)}) }

    it "hops to wait_destroy if destroy_base_machine_images is set" do
      prog.incr_destroy_base_machine_images
      expect { prog.wait }.to hop("wait_destroy")
      expect(metals.map { it.refresh.destroy_set? }).to all(be true)
    end

    it "naps for 1 hour if destroy_base_machine_images is not set" do
      expect { prog.wait }.to nap(60 * 60)
    end
  end

  describe "#wait_destroy" do
    before { refresh_frame(prog, new_values: {"base_machine_image_version_ids" => metals.map(&:id)}) }

    it "naps until all machine image versions are destroyed" do
      expect { prog.wait_destroy }.to nap(15)
    end

    it "pops when all machine image versions are destroyed" do
      metals.each(&:destroy)
      expect { prog.wait_destroy }.to exit({"msg" => "Base machine images destroyed!"})
    end
  end

  describe "#failed" do
    it "naps for 15 seconds" do
      expect { prog.failed }.to nap(15)
    end
  end
end
