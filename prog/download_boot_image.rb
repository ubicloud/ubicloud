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
      ["almalinux-9", "x64", "9.5-20241120"] => "abddf01589d46c841f718cec239392924a03b34c4fe84929af5d543c50e37e37",
      ["almalinux-9", "arm64", "9.5-20241120"] => "5ede4affaad0a997a2b642f1628b6268bd8eba775f281346b75be3ed20ec369e",
      ["github-ubuntu-2404", "x64", "20250202.1.1"] => "fc61e227cc28b3ec0fdb5a7a4fc8d0ccd73c2b05baabf5a3dabd4aff8ba2104e",
      ["github-ubuntu-2404", "x64", "20250301.1.0"] => "fd5ac3bca432048e1992232151f3c048dfe7a011f793d48e98c38556ed9c0a1f",
      ["github-ubuntu-2404", "x64", "20250302.1.1"] => "c38a9bdd09d43ab7161c85253c350fe470264b32088376e6e02f5719253bf5d3",
      ["github-ubuntu-2404", "arm64", "20250202.1.1"] => "b78fd2bdf70599fb11d41406e05f6215676a07b4660e3b8cf7adb7ca460aa262",
      ["github-ubuntu-2404", "arm64", "20250301.1.0"] => "38d9944a4376ecfa0cfbd6a7c1027a8b2c6a09d85da3420e25a430077b4e9b6e",
      ["github-ubuntu-2404", "arm64", "20250302.1.1"] => "f305f68c77da3d02f134fc95da6d31f550c89b87b06e4d1662fbab4f52d9360f",
      ["github-ubuntu-2204", "x64", "20250202.1.1"] => "9e083f4da9c548fcb6260b8cf6e7676b4f7a4e0b8894c6140714c735d80b57d0",
      ["github-ubuntu-2204", "x64", "20250301.1.0"] => "8ab24da6554b92b1e2b71c504519516d04a05be604327356a31a988f9973b710",
      ["github-ubuntu-2204", "x64", "20250302.1.1"] => "6fbfe32776e9a0700e8e9ad969bfb2e0c2ac2aaa7d3ad9acdba3ae31f0055ad4",
      ["github-ubuntu-2204", "arm64", "20250202.1.1"] => "10cd760cb31133a2e28f001370462867868b16af6c3070ffd7dc29ee714b125f",
      ["github-ubuntu-2204", "arm64", "20250301.1.0"] => "2308b34c06e5092450f605641588feab3dbc9c4d7f1800b27ea3f87f39912d38",
      ["github-ubuntu-2204", "arm64", "20250302.1.1"] => "2adeebedb45d0a7833c5ff8cf5e231cfb6cf4f399c9f6605c86c16fc6595678c",
      ["github-ubuntu-2004", "x64", "20250202.1.1"] => "1abfeb25e6361c7a239a1b4bb7ec9b13beddc1c1a8e7006a0457599cf4263c8b",
      ["github-ubuntu-2004", "x64", "20250301.1.0"] => "52cd4e8cf0ce7b389909e3ef8042bcd8e322eb39bdf6255287801b6d3bcc8239",
      ["github-ubuntu-2004", "x64", "20250302.1.1"] => "bb97a2ca1eb2a15106e70bd77d11785494e13c4f381323618b505c691ea834b5",
      ["github-ubuntu-2004", "arm64", "20250202.1.1"] => "0c8b6e4a4e2fd1ce8f39a054007a0b45b291060ae905b4176e6e6783a0b22391",
      ["github-ubuntu-2004", "arm64", "20250301.1.0"] => "8c1baf8b7561d20686559371b4299d5bb08cadf5046e2659ca06274fc5825ad2",
      ["github-ubuntu-2004", "arm64", "20250302.1.1"] => "19c385b9debd3a8847e883ed7ad0dd87b3d67b036111d2ee3189c5bb04e81085",
      ["github-gpu-ubuntu-2204", "x64", "20250202.1.1"] => "d14d5e86479c4938acfcd8fb56bc930c94e7648138e48e9121c7c6f783623311",
      ["github-gpu-ubuntu-2204", "x64", "20250301.1.0"] => "a83fe38970025ecfc4182d0385a6d3a539f4536db1b7daf5200287a89b83b44c",
      ["github-gpu-ubuntu-2204", "x64", "20250302.1.1"] => "208c427919905a17f9d0f9b60607793484369361607831e405850f7210078a20",
      ["postgres16-ubuntu-2204", "x64", "20250206.1.0"] => "610d9fc543878683ddc54fd0f031436381f1824aba0087ee499dd672853b75b3",
      ["postgres17-ubuntu-2204", "x64", "20250206.1.0"] => "4cbd9d47400ac2e5ee03974c32e2c7557fcee4cd6883a19019c51539dcbaa7b0",
      ["postgres16-paradedb-ubuntu-2204", "x64", "20250123.1.0"] => "463460ed0c875ffcfdc74338133ca844a31673a08aec32920d5bd5d52320f832",
      ["postgres17-paradedb-ubuntu-2204", "x64", "20250123.1.0"] => "e150b0e9b6a5adc8550f2191276f603d120718e06c53bf398578a7d79dca7a84",
      ["postgres16-lantern-ubuntu-2204", "x64", "20250103.1.0"] => "bfb56867513045bc88396d529a3cc186dc44ba4d691acb51dbf45fc5a0eeb7e6",
      ["postgres17-lantern-ubuntu-2204", "x64", "20250103.1.0"] => "a95b2e5d03291783dc1753228d7a87949257a06c7b1eca2c94502ab21ffdecdb",
      ["ai-ubuntu-2404-nvidia", "x64", "20250301.1.0"] => "6392a94b248c5e299325f3687a5f48ae3a50cf5a10d54efd2be3bbea89f2f634",
      ["ai-model-empty", "x64", "20250317.1.0"] => "24529ea3cfb853c1350153dc3dd30aab62df352b8f46ad35f729cb9948190316",
      ["ai-model-gemma-2-2b-it", "x64", "20240918.1.0"] => "b726ead6d5f48fb8e6de7efb48fb22367c9a7c155cfee71a3a7e5527be5df08e",
      ["ai-model-llama-3-1-8b-it", "x64", "20250118.1.0"] => "7296f70a861c364f59c38b816e1210152ebafbec85ce797888c16b4d48a15e8f",
      ["ai-model-llama-3-2-1b-it", "x64", "20250203.1.0"] => "c32ba500156486d35d79c18a69a146278e2c408b0d433d7fb94d753b68fe5d3a",
      ["ai-model-llama-3-2-3b-it", "x64", "20241028.1.0"] => "023d2a285564f3b75413c537b1242e4c2acfea3d3f88912c595da80354516fba",
      ["ai-model-llama-guard-3-1b", "x64", "20241028.1.0"] => "ef85abe990d26ded8e231fd05195c580b517b6555fe8f1dc9463012ce3e93f3f",
      ["ai-model-llama-guard-3-8b", "x64", "20241028.1.0"] => "7f856f564626214a57f4788489b9e588ea63a537bd88aadb14e4745aab219c5c",
      ["ai-model-e5-mistral-7b-it", "x64", "20241016.1.0"] => "999b0ff41968ffede0408ce3d4a9a21ff23e391f7aeac2f2d492fd505e73826c",
      ["ai-model-llama-3-3-70b-it", "x64", "20241209.1.0"] => "b5a77810de7f01df5b76b6362fc5b4514cc16c6926ee203ecc8643233c6d2704",
      ["ai-model-llama-3-3-70b-turbo", "x64", "20250221.1.0"] => "833e62b949c4eb8aeccabaac4c14a8af525db30c490b2eea53b33093676c7d44",
      ["ai-model-qwen-2-5-14b-it", "x64", "20250118.1.0"] => "51a7fe8c520f39b8197c88426c8f37199bd3bd2afdae579b8877a604cd474021",
      ["ai-model-qwq-32b-preview", "x64", "20241209.1.0"] => "38ca4912134ed9b115726eff258666d68ce6df92330a3585d47494099821f9b1",
      ["ai-model-ds-r1-qwen-32b", "x64", "20250227.1.0"] => "16269ce8660413718c58b60c649042cca6cef2429f59f59e4c70bb5e951ebe74",
      ["ai-model-ds-r1-qwen-1-5b", "x64", "20250129.1.0"] => "9135a2e81fc6129d6d12bd633b5a30d4bfe2fd219ec5e370404758dda1159001",
      ["ai-model-ms-phi-4", "x64", "20250213.1.0"] => "0e998c4916c837c0992c4546404ecb51d0c5d5923f998f7cff0a9cddc5bf1689",
      ["ai-model-mistral-small-3", "x64", "20250217.1.0"] => "01ce8d1d0b7b0f717c51c26590234f4cb7971a9a5276de92b6cb4dc2c7a085e5"
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
