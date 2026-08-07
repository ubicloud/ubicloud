# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Test::KubernetesNodeImages do
  let(:location_id) { Location::HETZNER_FSN1_ID }
  let(:kubernetes_versions) { Option.selectable_kubernetes_versions }
  let(:prog) { described_class.new(described_class.assemble(location_id:, kubernetes_versions:)) }
  let(:image_project) { Project.create(name: "machine-images-service") }
  let(:metals) { kubernetes_versions.map { create_machine_image_version_metal(name: "kubernetes-#{it.tr(".", "_")}") } }

  describe ".assemble" do
    it "creates a strand with the versions to build" do
      strand = described_class.assemble(location_id:, kubernetes_versions:)
      expect(strand.stack.first.values_at("location_id", "kubernetes_versions")).to eq [location_id, kubernetes_versions]
    end
  end

  describe "#build_node_images" do
    it "starts a build for each version" do
      kubernetes_project = Project.create(name: "kubernetes-service")
      MachineImageStore.create(project_id: image_project.id, location_id:, provider: "r2", region: "auto", endpoint: "https://r2.cloudflare.com/", bucket: "test-bucket", access_key: "ak", secret_key: "sk")
      allow(Config).to receive_messages(kubernetes_service_project_id: kubernetes_project.id, machine_images_service_project_id: image_project.id)

      expect { prog.build_node_images }.to hop("wait_node_images")

      builds = prog.build_strand_ids.map { Strand[it] }
      expect(builds.map { it.stack.first.values_at("kubernetes_version", "image_version", "skip_verification") })
        .to eq(kubernetes_versions.map { [it, "e2e", true] })
    end
  end

  describe "#wait_node_images" do
    it "naps while a build is still running" do
      build = Strand.create(prog: "Kubernetes::BuildNodeImage", label: "build", stack: [{"kubernetes_version" => kubernetes_versions.first}])
      refresh_frame(prog, new_values: {"build_strand_ids" => [build.id]})

      expect { prog.wait_node_images }.to nap(10)
    end

    it "fails the test when a build failed" do
      build = Strand.create(prog: "Kubernetes::BuildNodeImage", label: "failed", stack: [{"kubernetes_version" => kubernetes_versions.first}])
      refresh_frame(prog, new_values: {"build_strand_ids" => [build.id]})

      expect { prog.wait_node_images }.to hop("failed")
      expect(prog.strand.exitval).to eq({msg: "Kubernetes node image build for #{kubernetes_versions.first} failed"})
    end

    it "records the built versions once every build has popped" do
      allow(Config).to receive(:machine_images_service_project_id).and_return(image_project.id)
      metals.each { it.machine_image_version.machine_image.update(project_id: image_project.id, location_id:, latest_version_id: it.id) }
      refresh_frame(prog, new_values: {"build_strand_ids" => [Strand.generate_uuid]})

      expect { prog.wait_node_images }.to hop("wait")
      expect(prog.machine_image_version_ids).to eq metals.map(&:id)
    end
  end

  describe "#wait" do
    before { refresh_frame(prog, new_values: {"machine_image_version_ids" => metals.map(&:id)}) }

    it "hops to wait_destroy when destroy_kubernetes_node_images is set" do
      prog.incr_destroy_kubernetes_node_images

      expect { prog.wait }.to hop("wait_destroy")
      expect(metals.map { it.refresh.destroy_set? }).to all(be true)
    end

    it "naps for an hour otherwise" do
      expect { prog.wait }.to nap(60 * 60)
    end
  end

  describe "#wait_destroy" do
    before { refresh_frame(prog, new_values: {"machine_image_version_ids" => metals.map(&:id)}) }

    it "naps until the versions are destroyed" do
      expect { prog.wait_destroy }.to nap(15)
    end

    it "pops once the versions are destroyed" do
      metals.each(&:destroy)

      expect { prog.wait_destroy }.to exit({"msg" => "Kubernetes node images destroyed!"})
    end
  end

  describe "#failed" do
    it "naps" do
      expect { prog.failed }.to nap(15)
    end
  end
end
