# frozen_string_literal: true

class Prog::Storage::SetupVhostBlockBackend < Prog::Base
  subject_is :sshable, :vm_host

  SUPPORTED_VHOST_BLOCK_BACKEND_VERSIONS = [
    ["v0.1-1", "x64"],
    ["v0.1-1", "arm64"]
  ]

  def self.assemble(vm_host_id, version, allocation_weight: 0)
    Strand.create_with_id(
      prog: "Storage::SetupVhostBlockBackend",
      label: "start",
      stack: [{
        "subject_id" => vm_host_id,
        "version" => version,
        "allocation_weight" => allocation_weight
      }]
    )
  end

  label def start
    version = frame["version"]
    arch = vm_host.arch
    fail "Unsupported version: #{version}, #{arch}" unless SUPPORTED_VHOST_BLOCK_BACKEND_VERSIONS.include? [version, arch]

    VhostBlockBackend.create(
      version: frame["version"],
      allocation_weight: 0,
      vm_host_id: vm_host.id
    ) { it.id = VhostBlockBackend.generate_uuid }

    hop_install_vhost_backend
  end

  label def install_vhost_backend
    q_version = frame["version"].shellescape
    sshable.cmd("sudo host/bin/setup-vhost-block-backend install #{q_version}")

    hop_update_database
  end

  label def update_database
    vhost_block_backend = VhostBlockBackend.where(vm_host_id: vm_host.id, version: frame["version"]).first

    vhost_block_backend.update(
      allocation_weight: frame["allocation_weight"]
    )

    pop "VhostBlockBackend was setup"
  end
end
