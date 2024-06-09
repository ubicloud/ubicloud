# frozen_string_literal: true

require "json"

class Prog::DownloadBootImage < Prog::Base
  subject_is :sshable, :vm_host

  def image_name
    @image_name ||= frame.fetch("image_name")
  end

  def version
    @version ||= frame.fetch("version") { default_boot_image_version(image_name) }
  end

  def download_from_blob_storage?
    image_name.start_with?("github", "postgres") || Config.e2e_test?
  end

  def default_boot_image_version(image_name)
    case image_name
    when "ubuntu-noble"
      Config.ubuntu_noble_version
    when "ubuntu-jammy"
      Config.ubuntu_jammy_version
    when "almalinux-9"
      Config.almalinux_9_version
    when "almalinux-8"
      Config.almalinux_8_version
    when "github-ubuntu-2204"
      Config.github_ubuntu_2204_version
    when "github-ubuntu-2004"
      Config.github_ubuntu_2004_version
    when "github-gpu-ubuntu-2204"
      Config.github_gpu_ubuntu_2204_version
    when "postgres-ubuntu-2204"
      Config.postgres_ubuntu_2204_version
    else
      fail "Unknown boot image: #{image_name}"
    end
  end

  def url
    @url ||=
      if frame["custom_url"]
        frame["custom_url"]
      elsif download_from_blob_storage?
        suffixes = {
          "github" => "raw",
          "postgres" => "raw",
          "ubuntu" => "img",
          "almalinux" => "qcow2"
        }
        image_family = image_name.split("-").first
        suffix = suffixes.fetch(image_family, nil)
        blob_storage_client.get_presigned_url("GET", Config.ubicloud_images_bucket_name, "#{image_name}-#{vm_host.arch}-#{version}.#{suffix}", 60 * 60).to_s
      elsif image_name == "ubuntu-noble"
        arch = (vm_host.arch == "x64") ? "amd64" : "arm64"
        "https://cloud-images.ubuntu.com/releases/noble/release-#{version}/ubuntu-24.04-server-cloudimg-#{arch}.img"
      elsif image_name == "ubuntu-jammy"
        arch = (vm_host.arch == "x64") ? "amd64" : "arm64"
        "https://cloud-images.ubuntu.com/releases/jammy/release-#{version}/ubuntu-22.04-server-cloudimg-#{arch}.img"
      elsif image_name == "almalinux-8"
        fail "Only x64 is supported for almalinux-8" unless vm_host.arch == "x64"
        "https://repo.almalinux.org/almalinux/8/cloud/x86_64/images/AlmaLinux-8-GenericCloud-#{version}.x86_64.qcow2"
      elsif image_name == "almalinux-9"
        arch = (vm_host.arch == "x64") ? "x86_64" : "aarch64"
        "https://repo.almalinux.org/almalinux/9/cloud/#{arch}/images/AlmaLinux-9-GenericCloud-#{version}.#{arch}.qcow2"
      else
        fail "Unknown image name: #{image_name}"
      end
  end

  def sha256_sum
    hashes = {
      ["ubuntu-noble", "x64", "20240523.1"] => "b60205f4cc48a24b999ad0bd61ceb9fe28abfe4ac3701acb7bb5d6b0b5fdc624",
      ["ubuntu-noble", "arm64", "20240523.1"] => "54f6b62cc8d393e5c82495a49b8980157dfa6a13b930d8d4170e34e30742d949",
      ["ubuntu-jammy", "x64", "20240319"] => "304983616fcba6ee1452e9f38993d7d3b8a90e1eb65fb0054d672ce23294d812",
      ["ubuntu-jammy", "arm64", "20240319"] => "40ea1181447b9395fa03f6f2c405482fe532a348cc46fbb876effcfbbb35336f",
      ["almalinux-8", "x64", "8.10-20240530"] => "41a6bcdefb35afbd2819f0e6c68005cd5e9a346adf2dc093b1116a2b7c647d86",
      ["almalinux-9", "x64", "9.4-20240507"] => "bff0885c804c01fff8aac4b70c9ca4f04e8c119f9ee102043838f33e06f58390",
      ["almalinux-9", "arm64", "9.4-20240507"] => "75b2e68f6aaa41c039274595ff15968201b7201a7f2f03b109af691f2d3687a1",
      ["github-ubuntu-2204", "x64", "20240422.1.0"] => "8b1b7af6941ce7b8b93d0c20af712e04e8ceedbd673b29fd4fba3406a3ba133c",
      ["github-ubuntu-2204", "arm64", "20240422.1.0"] => "e14a7176070af022ace0e057a93beaa420602fa331dc67353ea4ce2459344265",
      ["github-ubuntu-2004", "x64", "20240422.1.0"] => "cf4f3bd4fc43de5804eac32e810101fcfe078aafeb46cb5a34fff8f8f76b360d",
      ["github-ubuntu-2004", "arm64", "20240422.1.0"] => "3e34cf2cb05ff9ab8c915b556bf31f153e90b20de25551587fadbec81557204b",
      ["github-gpu-ubuntu-2204", "x64", "20240422.1.0"] => "5bb0577f9aaeae298f5a66403ae55b2092e790eb98ea7ef5812892211a55a548",
      ["postgres-ubuntu-2204", "x64", "20240226.1.0"] => "f8a2b78189239717355b54ecf62a504a349c96b1ab6a21919984f58c2a367617"
    }

    # YYY: In future all images should be checked for sha256 sum, so the nil
    # default will be removed.
    hashes.fetch([image_name, vm_host.arch, version], nil)
  end

  def blob_storage_client
    @blob_storage_client ||= Minio::Client.new(
      endpoint: Config.ubicloud_images_blob_storage_endpoint,
      access_key: Config.ubicloud_images_blob_storage_access_key,
      secret_key: Config.ubicloud_images_blob_storage_secret_key,
      ssl_ca_file_data: Config.ubicloud_images_blob_storage_certs
    )
  end

  label def start
    # YYY: we can remove this once we enforce it in the database layer.
    # Although the default version is used if version is not passed, adding
    # a sanity check here to make sure version is not passed as nil.
    fail "Version can not be passed as nil" if version.nil?

    fail "Image already exists on host" if vm_host.boot_images_dataset.where(name: image_name, version: version).count > 0

    BootImage.create_with_id(
      vm_host_id: vm_host.id,
      name: image_name,
      version: version,
      activated_at: nil,
      size_gib: 0
    )
    hop_download
  end

  label def download
    q_daemon_name = "download_#{image_name}_#{version}".shellescape
    case sshable.cmd("common/bin/daemonizer --check #{q_daemon_name}")
    when "Succeeded"
      sshable.cmd("common/bin/daemonizer --clean #{q_daemon_name}")
      hop_update_available_storage_space
    when "NotStarted"
      params_json = {
        image_name: image_name,
        url: url,
        version: version,
        sha256sum: sha256_sum,
        certs: download_from_blob_storage? ? Config.ubicloud_images_blob_storage_certs : nil
      }.to_json
      sshable.cmd("common/bin/daemonizer 'host/bin/download-boot-image' #{q_daemon_name}", stdin: params_json)
    when "Failed"
      if Config.production?
        BootImage.where(vm_host_id: vm_host.id, name: image_name, version: version).destroy
      else
        sshable.cmd("common/bin/daemonizer --clean #{q_daemon_name}")
      end
      fail "Failed to download '#{image_name}' image on #{vm_host}"
    end

    nap 15
  end

  label def update_available_storage_space
    image = BootImage[vm_host_id: vm_host.id, name: image_name, version: version]
    image_size_bytes = sshable.cmd("stat -c %s #{image.path.shellescape}").to_i
    image_size_gib = (image_size_bytes / 1024.0**3).ceil
    StorageDevice.where(vm_host_id: vm_host.id, name: "DEFAULT").update(
      available_storage_gib: Sequel[:available_storage_gib] - image_size_gib
    )
    image.update(size_gib: image_size_gib)
    hop_activate_boot_image
  end

  label def activate_boot_image
    BootImage.where(
      vm_host_id: vm_host.id,
      name: image_name,
      version: version
    ).update(activated_at: Time.now)
    pop({"msg" => "image downloaded", "name" => image_name, "version" => version})
  end
end
