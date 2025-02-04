# frozen_string_literal: true

class Prog::Storage::SetupSpdk < Prog::Base
  subject_is :sshable, :vm_host

  SUPPORTED_SPDK_VERSIONS = [
    ["v23.09-ubi-0.3", "x64"],
    ["v23.09-ubi-0.3", "arm64"]
  ]

  def self.assemble(vm_host_id, version, start_service: false, allocation_weight: 0)
    Strand.create_with_id(
      prog: "Storage::SetupSpdk",
      label: "start",
      stack: [{
        "subject_id" => vm_host_id,
        "version" => version,
        "start_service" => start_service,
        "allocation_weight" => allocation_weight
      }]
    )
  end

  label def start
    version = frame["version"]
    arch = vm_host.arch

    fail "Unsupported version: #{version}, #{arch}" unless SUPPORTED_SPDK_VERSIONS.include? [version, arch]

    fail "Can't install more than 2 SPDKs on a host" if vm_host.spdk_installations.length > 1

    fail "No available hugepages" if frame["start_service"] && vm_host.used_hugepages_1g > vm_host.total_hugepages_1g - 2

    SpdkInstallation.create(
      version: frame["version"],
      allocation_weight: 0,
      vm_host_id: vm_host.id,
      cpu_count: vm_host.spdk_cpu_count,
      hugepages: 4
    ) { _1.id = SpdkInstallation.generate_uuid }

    hop_install_spdk
  end

  label def install_spdk
    q_version = frame["version"].shellescape
    cpu_count = vm_host.spdk_cpu_count
    # YYY: drop the default value after updating production data
    os_version = vm_host.os_version || "ubuntu-22.04"
    sshable.cmd("sudo host/bin/setup-spdk install #{q_version} #{cpu_count} #{os_version.shellescape}")

    hop_start_service
  end

  label def start_service
    if frame["start_service"]
      q_version = frame["version"].shellescape
      sshable.cmd("sudo host/bin/setup-spdk start #{q_version}")
      sshable.cmd("sudo host/bin/setup-spdk verify #{q_version}")
    end

    hop_update_database
  end

  label def update_database
    spdk_installation = SpdkInstallation.where(
      version: frame["version"],
      vm_host_id: vm_host.id
    ).first

    spdk_installation.update(allocation_weight: frame["allocation_weight"])

    if frame["start_service"]
      VmHost.where(id: vm_host.id).update(
        used_hugepages_1g: Sequel[:used_hugepages_1g] + spdk_installation.hugepages
      )
    end

    pop "SPDK was setup"
  end
end
