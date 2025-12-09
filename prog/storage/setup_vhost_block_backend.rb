# frozen_string_literal: true

class Prog::Storage::SetupVhostBlockBackend < Prog::Base
  subject_is :sshable, :vm_host

  SUPPORTED_VHOST_BLOCK_BACKEND_VERSIONS = [
    ["v0.3.0", "x64"],
    ["v0.3.0", "arm64"],
    ["v0.2.1", "x64"],
    ["v0.2.1", "arm64"]
  ].freeze.each(&:freeze)

  def self.assemble(vm_host_id, version, allocation_weight: 0)
    Strand.create(
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
    )

    register_deadline(nil, 5 * 60)
    hop_install_vhost_backend
  end

  label def install_vhost_backend
    version = frame["version"]
    name = "setup-vhost-block-backend-#{version}"
    case sshable.cmd("common/bin/daemonizer --check :name", name:)
    when "Succeeded"
      sshable.cmd("common/bin/daemonizer --clean :name", name:)
      VhostBlockBackend.first(
        vm_host_id: vm_host.id, version: frame["version"]
      ).update(allocation_weight: frame["allocation_weight"])
      pop "VhostBlockBackend was setup"
    when "Failed", "NotStarted"
      d_command = NetSsh.command("sudo host/bin/setup-vhost-block-backend install :version", version:)
      sshable.cmd("common/bin/daemonizer :d_command :name", name:, d_command:)
    end

    nap 5
  end
end
