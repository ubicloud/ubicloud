# frozen_string_literal: true

class Prog::Kubernetes::BuildNodeImage < Prog::Base
  semaphore :destroy

  frame_reader :kubernetes_version, :location_id, :image_version, :machine_image_id, :vm_id, :skip_verification
  frame_accessor :machine_image_version_id, :verify_cluster_id, :boot_id

  BUILD_UNIT = "build_node_image"

  def self.assemble(kubernetes_version:, location_id:, image_version:, skip_verification: false)
    fail "invalid kubernetes version: #{kubernetes_version}" unless Option.kubernetes_versions.include?(kubernetes_version)
    fail "invalid location for kubernetes: #{location_id}" if Option.kubernetes_locations.none? { it.id == location_id }
    fail "invalid image version: #{image_version}" unless Validation::ALLOWED_MACHINE_IMAGE_VERSION_LABEL_PATTERN.match?(image_version)
    fail "no kubernetes service project" unless Project[Config.kubernetes_service_project_id]
    fail "no machine images service project" unless (image_project = Project[Config.machine_images_service_project_id])
    fail "no machine image store for #{location_id}" unless image_project.machine_image_store_for(location_id)

    DB.transaction do
      name = "kubernetes-#{kubernetes_version.tr(".", "_")}"
      machine_image = MachineImage.first(project_id: image_project.id, location_id:, name:) ||
        MachineImage.create(project_id: image_project.id, location_id:, name:, arch: "x64")
      vm_id = Prog::Vm::Nexus.assemble_with_sshable(Config.kubernetes_service_project_id, sshable_unix_user: "ubi", location_id:, size: "standard-2", storage_volumes: [{encrypted: true, size_gib: 10}], boot_image: "ubuntu-noble", enable_ip4: true).id

      Strand.create(prog: "Kubernetes::BuildNodeImage", label: "wait_vm", stack: [{
        "kubernetes_version" => kubernetes_version,
        "location_id" => location_id,
        "image_version" => image_version,
        "machine_image_id" => machine_image.id,
        "vm_id" => vm_id,
        "skip_verification" => skip_verification,
      }])
    end
  end

  label def wait_vm
    nap 10 unless vm.display_state == "running"
    hop_bootstrap_rhizome
  end

  label def bootstrap_rhizome
    bud Prog::BootstrapRhizome, {"target_folder" => "kubernetes", "subject_id" => vm_id, "user" => "ubi"}
    hop_wait_bootstrap_rhizome
  end

  label def wait_bootstrap_rhizome
    reap(:build)
  end

  label def build
    register_deadline("sanitize", 15 * 60)

    case (state = vm.sshable.d_check(BUILD_UNIT))
    when "Succeeded"
      vm.sshable.d_clean(BUILD_UNIT)
      hop_restart
    when "NotStarted"
      vm.sshable.d_run(BUILD_UNIT, "kubernetes/bin/build-node-image", kubernetes_version)
      nap 10
    when "InProgress"
      nap 10
    else
      trigger_page("build #{state}")
      hop_failed
    end
  end

  label def restart
    vm.sshable.cmd("sync")
    self.boot_id = vm.sshable.cmd("cat /proc/sys/kernel/random/boot_id").strip
    vm.incr_restart
    hop_wait_restart
  end

  label def wait_restart
    nap 5 unless vm.sshable.available?
    nap 5 if vm.sshable.cmd("cat /proc/sys/kernel/random/boot_id").strip == boot_id

    hop_sanitize
  end

  label def sanitize
    vm.sshable.cmd("kubernetes/bin/sanitize-node-image")
    vm.incr_stop
    hop_wait_stopped
  end

  label def wait_stopped
    nap 10 unless vm.display_state == "stopped"
    hop_capture
  end

  label def capture
    self.machine_image_version_id = Prog::MachineImage::VersionMetalNexus.assemble_from_vm(machine_image, image_version, vm, machine_image_store, destroy_source_after: true, set_as_latest: false).id
    hop_wait_capture
  end

  label def wait_capture
    case MachineImageVersionMetal[machine_image_version_id].status
    when "ready"
      skip_verification ? hop_promote : hop_verify
    when "failed"
      trigger_page("capture failed")
      hop_failed
    else
      nap 15
    end
  end

  label def verify
    register_deadline("promote", 30 * 60)

    cluster_name = "verify-#{MachineImageVersion[machine_image_version_id].ubid}"
    cluster = Prog::Kubernetes::KubernetesClusterNexus.assemble(name: cluster_name, project_id: Config.kubernetes_service_project_id, location_id:, version: kubernetes_version, cp_node_count: 3, machine_image_version_id:).subject
    Prog::Kubernetes::KubernetesNodepoolNexus.assemble(name: "#{cluster_name}-np", node_count: 1, kubernetes_cluster_id: cluster.id, machine_image_version_id:)

    self.verify_cluster_id = cluster.id
    hop_wait_verify
  end

  label def wait_verify
    nap 30 unless verify_cluster.strand.label == "wait" && verify_cluster.nodepools.all? { it.strand.label == "wait" }
    hop_promote
  end

  label def promote
    verify_cluster&.incr_destroy
    machine_image.update(latest_version_id: machine_image_version_id)
    pop "Kubernetes node image built"
  end

  label def failed
    nap 60 * 60
  end

  label def destroy
    reap do
      vm&.incr_destroy
      verify_cluster&.incr_destroy
      MachineImageVersionMetal.where(id: machine_image_version_id).first&.incr_destroy
      Page.from_tag_parts("KubernetesNodeImageBuild", machine_image_id, image_version)&.incr_resolve
      pop "Kubernetes node image build destroyed"
    end
  end

  def trigger_page(reason)
    Prog::PageNexus.assemble(
      "Kubernetes node image #{machine_image.name}@#{image_version} #{reason}",
      ["KubernetesNodeImageBuild", machine_image_id, image_version],
      machine_image.ubid,
      severity: "info",
      extra_data: {kubernetes_version:, image_version:, builder_vm_id: vm_id, reason:},
    )
  end

  def vm
    @vm ||= Vm[vm_id]
  end

  def machine_image
    @machine_image ||= MachineImage[machine_image_id]
  end

  def verify_cluster
    @verify_cluster ||= KubernetesCluster.where(id: verify_cluster_id).first
  end

  def machine_image_store
    @machine_image_store ||= Project[Config.machine_images_service_project_id].machine_image_store_for(location_id)
  end
end
