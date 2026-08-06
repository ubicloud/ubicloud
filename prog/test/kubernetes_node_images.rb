# frozen_string_literal: true

class Prog::Test::KubernetesNodeImages < Prog::Test::Base
  semaphore :destroy_kubernetes_node_images
  frame_reader :location_id, :kubernetes_versions
  frame_accessor :build_strand_ids, :machine_image_version_ids

  def self.assemble(location_id:, kubernetes_versions:)
    Strand.create(
      prog: "Test::KubernetesNodeImages",
      label: "build_node_images",
      stack: [{
        "location_id" => location_id,
        "kubernetes_versions" => kubernetes_versions,
      }],
    )
  end

  label def build_node_images
    self.build_strand_ids = kubernetes_versions.map {
      Prog::Kubernetes::BuildNodeImage.assemble(kubernetes_version: it, location_id:, image_version: "e2e", skip_verification: true).id
    }
    hop_wait_node_images
  end

  label def wait_node_images
    build_strand_ids.each do |build_strand_id|
      # A build that popped leaves no strand behind, so a missing row is success
      next unless (st = Strand[build_strand_id])
      fail_test "Kubernetes node image build for #{st.stack.first["kubernetes_version"]} failed" if st.label == "failed"
      nap 10
    end

    self.machine_image_version_ids = kubernetes_versions.map { machine_image(it).latest_version_id }
    hop_wait
  end

  label def wait
    when_destroy_kubernetes_node_images_set? do
      MachineImageVersionMetal.incr_destroy(machine_image_version_ids)
      hop_wait_destroy
    end

    nap 60 * 60
  end

  label def wait_destroy
    nap 15 unless MachineImageVersionMetal.where(id: machine_image_version_ids).empty?
    pop "Kubernetes node images destroyed!"
  end

  label def failed
    nap 15
  end

  def machine_image(kubernetes_version)
    MachineImage.first(
      project_id: Config.machine_images_service_project_id,
      location_id:,
      name: "kubernetes-#{kubernetes_version.tr(".", "_")}",
    )
  end
end
