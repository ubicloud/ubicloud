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
    image_name.start_with?("github", "postgres", "ai-") || Config.production?
  end

  def default_boot_image_version(image_name)
    config_name = image_name.tr("-", "_") + "_version"
    fail "Unknown boot image: #{image_name}" unless Config.respond_to?(config_name)
    Config.send(config_name)
  end

  def url
    @url ||=
      if frame["custom_url"]
        frame["custom_url"]
      elsif download_from_blob_storage?
        suffixes = {
          "github" => "raw",
          "postgres16" => "raw",
          "postgres17" => "raw",
          "ubuntu" => "img",
          "almalinux" => "qcow2",
          "debian" => "raw",
          "ai" => "raw"
        }
        image_family = image_name.split("-").first
        suffix = suffixes.fetch(image_family, nil)
        arch = image_name.start_with?("ai-model") ? "-" : "-#{vm_host.arch}-"
        blob_storage_client.get_presigned_url("GET", Config.ubicloud_images_bucket_name, "#{image_name}#{arch}#{version}.#{suffix}", 60 * 60).to_s
      elsif image_name == "ubuntu-noble"
        arch = vm_host.render_arch(arm64: "arm64", x64: "amd64")
        "https://cloud-images.ubuntu.com/releases/noble/release-#{version}/ubuntu-24.04-server-cloudimg-#{arch}.img"
      elsif image_name == "ubuntu-jammy"
        arch = vm_host.render_arch(arm64: "arm64", x64: "amd64")
        "https://cloud-images.ubuntu.com/releases/jammy/release-#{version}/ubuntu-22.04-server-cloudimg-#{arch}.img"
      elsif image_name == "debian-12"
        arch = vm_host.render_arch(arm64: "arm64", x64: "amd64")
        "https://cloud.debian.org/images/cloud/bookworm/#{version}/debian-12-genericcloud-#{arch}-#{version}.raw"
      elsif image_name == "almalinux-9"
        arch = vm_host.render_arch(arm64: "aarch64", x64: "x86_64")
        "https://repo.almalinux.org/almalinux/9/cloud/#{arch}/images/AlmaLinux-9-GenericCloud-#{version}.#{arch}.qcow2"
      else
        fail "Unknown image name: #{image_name}"
      end
  end

  def sha256_sum
    hashes = {
      ["ubuntu-noble", "x64", "20240523.1"] => "b60205f4cc48a24b999ad0bd61ceb9fe28abfe4ac3701acb7bb5d6b0b5fdc624",
      ["ubuntu-noble", "arm64", "20240523.1"] => "54f6b62cc8d393e5c82495a49b8980157dfa6a13b930d8d4170e34e30742d949",
      ["ubuntu-noble", "x64", "20240702"] => "182dc760bfca26c45fb4e4668049ecd4d0ecdd6171b3bae81d0135e8f1e9d93e",
      ["ubuntu-noble", "arm64", "20240702"] => "5fe06e10a3b53cfff06edcb8595552b1f0372265b69fa424aa464eb4bcba3b09",
      ["ubuntu-jammy", "x64", "20240319"] => "304983616fcba6ee1452e9f38993d7d3b8a90e1eb65fb0054d672ce23294d812",
      ["ubuntu-jammy", "arm64", "20240319"] => "40ea1181447b9395fa03f6f2c405482fe532a348cc46fbb876effcfbbb35336f",
      ["ubuntu-jammy", "x64", "20240701"] => "769f0355acc3f411251aeb96401a827248aae838b91c637d991ea51bed30eeeb",
      ["ubuntu-jammy", "arm64", "20240701"] => "76423945c97fddd415fa17610c7472b07c46d6758d42f4f706f1bbe972f51155",
      ["debian-12", "arm64", "20241004-1890"] => "7965a9b9f02eb473138e6357def557029053178e4cd37c19e620f674ca7224c0",
      ["debian-12", "x64", "20241004-1890"] => "5af3d0e134eb3560ab035021763401d1ec72a25c761fe0ce964351e1409c523d",
      ["almalinux-9", "x64", "9.4-20240507"] => "bff0885c804c01fff8aac4b70c9ca4f04e8c119f9ee102043838f33e06f58390",
      ["almalinux-9", "arm64", "9.4-20240507"] => "75b2e68f6aaa41c039274595ff15968201b7201a7f2f03b109af691f2d3687a1",
      ["almalinux-9", "x64", "9.4-20240805"] => "4f2984589020c0d82b9a410cf9e29715a607c948dfdca652025cdc79ddb5e816",
      ["almalinux-9", "arm64", "9.4-20240805"] => "433e7a79b7c49007723851b7721c69a8f0a08be48969c04c1c9252cc16adc893",
      ["github-ubuntu-2404", "x64", "20240818.1.0"] => "1dcb86e9d382f35df537b50d421037ac797d854de59cba574232c401620814cf",
      ["github-ubuntu-2404", "x64", "20241006.1.0"] => "b8949833d5ade91b2ec71526390d970cd88bd1f9150a3a95827bdbf68ec649c8",
      ["github-ubuntu-2404", "arm64", "20241006.1.0"] => "20b117cc4b246301385805ed486245f87800306dfb9d347341c0847e3f3cec2f",
      ["github-ubuntu-2204", "x64", "20240818.1.0"] => "7f1b4366cb0fe7021afbf84129c5b2fba07bb513216708871c3024443a7b52fa",
      ["github-ubuntu-2204", "x64", "20241006.1.0"] => "d0ced50be5ea43e1bb413cc8eef8fd21d63643ee19189637331419b882ad58e3",
      ["github-ubuntu-2204", "arm64", "20240818.1.0"] => "74a7ab1b0d18825057b7366849305e49c063cf26cde0ed8a3f6d51a82c35c27b",
      ["github-ubuntu-2204", "arm64", "20241006.1.0"] => "4a6994c7664eaea7bb120329513ed5cacbf85c16b0030dd5ee838bcd40a90152",
      ["github-ubuntu-2004", "x64", "20240818.1.0"] => "e5af8ed1204241a884a01f044fc01ca0fa3f50bf2bea3fb12e27a523135e50a3",
      ["github-ubuntu-2004", "x64", "20241006.1.0"] => "e87dc79f31ae0fe85370b910e615a341ad1bd657d93423575173867b23992315",
      ["github-ubuntu-2004", "arm64", "20240818.1.0"] => "0609ee072f53af0ca402b7d769c0986ad8a36a6eb19229f01b0195bba7ed8ae2",
      ["github-ubuntu-2004", "arm64", "20241006.1.0"] => "6582137985903269787ce024054f636c06e6309968afe61fef569f61d733626f",
      ["github-gpu-ubuntu-2204", "x64", "20240818.1.0"] => "c366cc99107b1ea9c12cc6cfc03073a90f3aad011e333a59e0b6cfdc36776568",
      ["github-gpu-ubuntu-2204", "x64", "20241006.1.0"] => "ef2d6bab4dcbd7f4c72ba213dea76d06da06af33750fc8477efff03ea9ff23e9",
      ["postgres16-ubuntu-2204", "x64", "20241022.1.0"] => "9e719cebae7f9700bf1d80855fd12f4cf9ea75cd82887fab9b2ee7ab4a292d25",
      ["postgres17-ubuntu-2204", "x64", "20241022.1.0"] => "ad2c1dd2029bd9ffaff105ca231d820d59b318a9b32c0155d8d5baa13343e6fa",
      ["postgres16-paradedb-ubuntu-2204", "x64", "20241022.1.0"] => "1256a2e13f059f08747df6a0b2125ecbc756aa34666d7d1d5c86b32f8fe4b4d0",
      ["postgres17-paradedb-ubuntu-2204", "x64", "20241022.1.0"] => "d510cbc817114d424266cfca37deb011ae31b071c52f2013f98af17f6c0b032f",
      ["postgres16-lantern-ubuntu-2204", "x64", "20241010.1.0"] => "608766a3dc4be757c32c2855893ebaf5d92a55675205cd4c9aec1b0a8bc274fb",
      ["ai-ubuntu-2404-nvidia", "x64", "20241028.1.0"] => "fb7e78641714601ad883eb210eb0c54f30f3e21a8fd438d204a58c197a314291",
      ["ai-model-gemma-2-2b-it", "x64", "20240918.1.0"] => "b726ead6d5f48fb8e6de7efb48fb22367c9a7c155cfee71a3a7e5527be5df08e",
      ["ai-model-llama-guard-3-1b", "x64", "20241028.1.0"] => "ef85abe990d26ded8e231fd05195c580b517b6555fe8f1dc9463012ce3e93f3f",
      ["ai-model-e5-mistral-7b-it", "x64", "20241016.1.0"] => "999b0ff41968ffede0408ce3d4a9a21ff23e391f7aeac2f2d492fd505e73826c"
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
