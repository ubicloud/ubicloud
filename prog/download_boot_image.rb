# frozen_string_literal: true

require "json"

class Prog::DownloadBootImage < Prog::Base
  subject_is :sshable, :vm_host

  def image_name
    @image_name ||= frame.fetch("image_name")
  end

  def version
    @version ||= frame.fetch("version")
  end

  def download_from_blob_storage?
    image_name.start_with?("github", "postgres")
  end

  def url
    # YYY: Should we get ubuntu & almalinux urls here? Since we might start
    # putting all images into the blob storage in future, we're postponing the
    # decision and keeping the current logic (i.e. formula based URL in the
    # rhizome side).
    @url ||=
      if frame["custom_url"]
        frame["custom_url"]
      elsif download_from_blob_storage?
        blob_storage_client.get_presigned_url("GET", Config.ubicloud_images_bucket_name, "#{image_name}-#{vm_host.arch}-#{version}.raw", 60 * 60).to_s
      end
  end

  def sha256_sum
    hashes = {
      ["ubuntu-jammy", "x64", "20240319"] => "304983616fcba6ee1452e9f38993d7d3b8a90e1eb65fb0054d672ce23294d812",
      ["ubuntu-jammy", "arm64", "20240319"] => "40ea1181447b9395fa03f6f2c405482fe532a348cc46fbb876effcfbbb35336f",
      ["almalinux-9.3", "x64", "20231113"] => "6bbd060c971fd827a544c7e5e991a7d9e44460a449d2d058a0bb1290dec5a114",
      ["almalinux-9.3", "arm64", "20231113"] => "a064715bc755346d5a8e1a4c6b1b7abffe4de03f1b0584942d5483ed32aafd67",
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
    fail "Image already exists on host" if vm_host.boot_images_dataset.where(name: image_name, version: version).count > 0
    BootImage.create_with_id(
      vm_host_id: vm_host.id,
      name: image_name,
      version: version,
      activated_at: nil
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
      BootImage.where(vm_host_id: vm_host.id, name: image_name, version: version).destroy
      fail "Failed to download '#{image_name}' image on #{vm_host}"
    end

    nap 15
  end

  label def update_available_storage_space
    # YYY: version will be enforced in future.
    image_path =
      version ?
        "/var/storage/images/#{image_name}-#{version}.raw" :
        "/var/storage/images/#{image_name}.raw"
    image_size_bytes = sshable.cmd("stat -c %s #{image_path}").to_i
    image_size_gib = (image_size_bytes / 1024.0**3).ceil
    StorageDevice.where(vm_host_id: vm_host.id, name: "DEFAULT").update(
      available_storage_gib: Sequel[:available_storage_gib] - image_size_gib
    )
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
