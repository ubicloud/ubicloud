# frozen_string_literal: true

class Prog::Storage::SetupVhostBlockBackend < Prog::Base
  subject_is :sshable, :vm_host
  frame_reader :version, :allocation_weight, :disable_others, :vhost_block_backend_id

  SUPPORTED_VHOST_BLOCK_BACKEND_VERSIONS = [
    ["v0.5.1", "x64"],
    ["v0.5.1", "arm64"],
    ["v0.4.2", "x64"],
    ["v0.4.2", "arm64"],
    ["v0.3.1", "x64"],
    ["v0.3.1", "arm64"],
    ["v0.2.2", "x64"],
    ["v0.2.2", "arm64"],
  ].freeze.each(&:freeze)

  def self.assemble(vm_host_id, version, allocation_weight: 100, disable_others: true)
    fail "Cannot disable other backends without enabling this one" if allocation_weight == 0 && disable_others

    arch = VmHost.with_pk!(vm_host_id).arch
    fail "Unsupported version: #{version}, #{arch}" unless SUPPORTED_VHOST_BLOCK_BACKEND_VERSIONS.include? [version, arch]

    DB.transaction do
      vbb = VhostBlockBackend.create(version:, allocation_weight: 0, vm_host_id:)

      Strand.create(
        prog: "Storage::SetupVhostBlockBackend",
        label: "start",
        stack: [{
          "subject_id" => vm_host_id,
          "version" => version,
          "allocation_weight" => allocation_weight,
          "disable_others" => disable_others,
          "vhost_block_backend_id" => vbb.id,
        }],
      )
    end
  end

  label def start
    register_deadline(nil, 5 * 60)
    hop_install_vhost_backend
  end

  label def install_vhost_backend
    name = "setup-vhost-block-backend-#{version}"
    case sshable.cmd("common/bin/daemonizer --check :name", name:)
    when "Succeeded"
      sshable.cmd("common/bin/daemonizer --clean :name", name:)
      VhostBlockBackend.with_pk!(vhost_block_backend_id).update(allocation_weight:)
      vm_host.vhost_block_backends_dataset.exclude(id: vhost_block_backend_id).update(allocation_weight: 0) if disable_others
      pop "VhostBlockBackend was setup"
    when "Failed", "NotStarted"
      d_command = NetSsh.command("sudo host/bin/setup-vhost-block-backend install :version", version:)
      sshable.cmd("common/bin/daemonizer :d_command :name", name:, d_command:)
    end

    nap 5
  end
end
