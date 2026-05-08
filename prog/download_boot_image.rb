# frozen_string_literal: true

require "json"
require "aws-sdk-s3"

class Prog::DownloadBootImage < Prog::Base
  subject_is :sshable, :vm_host
  semaphore :cancel

  def image_name
    @image_name ||= frame.fetch("image_name")
  end

  def version
    @version ||= frame["version"] || latest_boot_image_version(image_name)
  end

  def image
    @image ||= BootImage[vm_host_id: vm_host.id, name: image_name, version:]
  end

  def download_from_blob_storage?
    image_name.start_with?("github", "postgres", "ai-", "kubernetes", "gpu") || Config.production?
  end

  def latest_boot_image_version(image_name)
    arch_versions = BOOT_IMAGE_SHA256.dig(image_name, vm_host.arch)
    fail "Unknown boot image: #{image_name}" unless arch_versions && !arch_versions.empty?

    arch_versions.keys.max
  end

  def download_from_r2?
    frame["download_r2"] || Config.production?
  end

  def url
    @url ||=
      if frame["custom_url"]
        frame["custom_url"]
      elsif download_from_blob_storage?
        suffixes = {
          "github" => "raw",
          "postgres" => "raw",
          "postgres16" => "raw",
          "postgres17" => "raw",
          "ubuntu" => "img",
          "almalinux" => "qcow2",
          "debian" => "raw",
          "ai" => "raw",
          "kubernetes" => "raw",
          "gpu" => "raw",
        }
        image_family = image_name.split("-").first
        suffix = suffixes.fetch(image_family, nil)
        arch = image_name.start_with?("ai-model") ? "-" : "-#{vm_host.arch}-"
        key = "#{image_name}#{arch}#{version}.#{suffix}"
        download_from_r2? ? r2_signed_url(key) : minio_signed_url(key)
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

  BOOT_IMAGE_SHA256 = {
    "ubuntu-noble" => {
      "x64" => {
        "20240523.1" => "b60205f4cc48a24b999ad0bd61ceb9fe28abfe4ac3701acb7bb5d6b0b5fdc624",
        "20240702" => "182dc760bfca26c45fb4e4668049ecd4d0ecdd6171b3bae81d0135e8f1e9d93e",
        "20250502.1" => "8e7d1781c14d309f4ad6fa01d6cdb5fbf6adf95a509394135634f6a283d1f33f",
      },
      "arm64" => {
        "20240523.1" => "54f6b62cc8d393e5c82495a49b8980157dfa6a13b930d8d4170e34e30742d949",
        "20240702" => "5fe06e10a3b53cfff06edcb8595552b1f0372265b69fa424aa464eb4bcba3b09",
        "20250502.1" => "5452ba9308557ef728078e829c2f221dfd4c05635fe67037d4f714efd12dbdbc",
      },
    },
    "ubuntu-jammy" => {
      "x64" => {
        "20240319" => "304983616fcba6ee1452e9f38993d7d3b8a90e1eb65fb0054d672ce23294d812",
        "20240701" => "769f0355acc3f411251aeb96401a827248aae838b91c637d991ea51bed30eeeb",
        "20250508" => "0cf20b41a17dbea17b2ac2a08c1c9b677748940c11a0381a02931e0af1a1fb52",
      },
      "arm64" => {
        "20240319" => "40ea1181447b9395fa03f6f2c405482fe532a348cc46fbb876effcfbbb35336f",
        "20240701" => "76423945c97fddd415fa17610c7472b07c46d6758d42f4f706f1bbe972f51155",
        "20250508" => "e2b20e818549db10486373927dd0feedd681a32dcbcd8a0bc2f2bd2f411c9f8b",
      },
    },
    "debian-12" => {
      "x64" => {
        "20241004-1890" => "5af3d0e134eb3560ab035021763401d1ec72a25c761fe0ce964351e1409c523d",
        "20250428-2096" => "1619b87079d6c0aa6194d0de6fdfc0b874ea0afd08d4153b0074f8276785661f",
      },
      "arm64" => {
        "20241004-1890" => "7965a9b9f02eb473138e6357def557029053178e4cd37c19e620f674ca7224c0",
        "20250428-2096" => "c6d1639e8a4d10cd7cdaeed618a7794d6fdd44df4a04df2fbfb7e490f2a67141",
      },
    },
    "almalinux-9" => {
      "x64" => {
        "9.5-20241120" => "abddf01589d46c841f718cec239392924a03b34c4fe84929af5d543c50e37e37",
        "9.6-20250522" => "b08cd5db79bf32860412f5837e8c7b8df9447e032376e3c622840b31aaf26bc6",
        "9.7-20251118" => "5ff9c048859046f41db4a33b1f1a96675711288078aac66b47d0be023af270d1",
      },
      "arm64" => {
        "9.5-20241120" => "5ede4affaad0a997a2b642f1628b6268bd8eba775f281346b75be3ed20ec369e",
        "9.6-20250522" => "47e6801d066c311c44a5ce8100bed16b5976bde610e599dd384d1dca73b31ac5",
        "9.7-20251118" => "c6c09af3b5be62e0ca82ccfafe0b1de9be90890fa8fddbd6118fa8b76b36de2d",
      },
    },
    "github-ubuntu-2404" => {
      "x64" => {
        "20260408.1.0" => "1495548c90309169f57fbedf72ee43217c8c0bbff5910d6e4942b3d0787feca5",
        "20260508.1.0" => "5ad16e9ad7128b4390c910e95fbcfc1c7d1920857d5facbb892b4afcfb1022ea",
      },
      "arm64" => {
        "20260401.1.0" => "2bb2b5d40a7bb8b18f2813073e5e1954ba96c6e389f63cf140db47e2f43b6367",
        "20260508.1.0" => "bdbb69919aa9324adcb30a687911b1e8999727d13c2e4ba19deb4d418699630b",
      },
    },
    "github-ubuntu-2204" => {
      "x64" => {
        "20260401.1.0" => "a39e9ac4b7b8511cf30b24965fb14d21a456f930e9fc54c0831d67b24e24744e",
        "20260508.1.0" => "af45cd5817d13f8ee488f9f2c657cde80e73ce58af6b2c036d89eb3756235d04",
      },
      "arm64" => {
        "20260401.1.0" => "79032108974f6f9eb22e22021f27d42e5d7ed4984758030ea5a42c0c16d03532",
        "20260508.1.0" => "387f875f8c15a4bd6d6be497f47ff283d51ac91964f5bbc1b5a911af888c4d8a",
      },
    },
    "postgres-ubuntu-2204" => {
      "x64" => {
        "20260410.1.1" => "6fc6b0670829bfaa0e1312259b09ee4189046d06d18b5e96b877897b37d81aef",
      },
    },
    "postgres16-lantern-ubuntu-2204" => {
      "x64" => {
        "20250103.1.0" => "bfb56867513045bc88396d529a3cc186dc44ba4d691acb51dbf45fc5a0eeb7e6",
      },
    },
    "postgres17-lantern-ubuntu-2204" => {
      "x64" => {
        "20250103.1.0" => "a95b2e5d03291783dc1753228d7a87949257a06c7b1eca2c94502ab21ffdecdb",
      },
    },
    "ai-ubuntu-2404-nvidia" => {
      "x64" => {
        "20250505.1.0" => "8d438d372238d46739ace4337634f3489dc4f18496a970fda6b6e60226307eaa",
      },
    },
    "ai-model-empty" => {
      "x64" => {
        "20250317.1.0" => "24529ea3cfb853c1350153dc3dd30aab62df352b8f46ad35f729cb9948190316",
      },
    },
    "ai-model-gemma-2-2b-it" => {
      "x64" => {
        "20240918.1.0" => "b726ead6d5f48fb8e6de7efb48fb22367c9a7c155cfee71a3a7e5527be5df08e",
      },
    },
    "ai-model-llama-3-1-8b-it" => {
      "x64" => {
        "20250118.1.0" => "7296f70a861c364f59c38b816e1210152ebafbec85ce797888c16b4d48a15e8f",
      },
    },
    "ai-model-llama-3-2-1b-it" => {
      "x64" => {
        "20250203.1.0" => "c32ba500156486d35d79c18a69a146278e2c408b0d433d7fb94d753b68fe5d3a",
      },
    },
    "ai-model-llama-3-2-3b-it" => {
      "x64" => {
        "20241028.1.0" => "023d2a285564f3b75413c537b1242e4c2acfea3d3f88912c595da80354516fba",
      },
    },
    "ai-model-llama-guard-3-1b" => {
      "x64" => {
        "20241028.1.0" => "ef85abe990d26ded8e231fd05195c580b517b6555fe8f1dc9463012ce3e93f3f",
      },
    },
    "ai-model-llama-guard-3-8b" => {
      "x64" => {
        "20241028.1.0" => "7f856f564626214a57f4788489b9e588ea63a537bd88aadb14e4745aab219c5c",
      },
    },
    "ai-model-e5-mistral-7b-it" => {
      "x64" => {
        "20241016.1.0" => "999b0ff41968ffede0408ce3d4a9a21ff23e391f7aeac2f2d492fd505e73826c",
      },
    },
    "ai-model-llama-3-3-70b-it" => {
      "x64" => {
        "20241209.1.0" => "b5a77810de7f01df5b76b6362fc5b4514cc16c6926ee203ecc8643233c6d2704",
      },
    },
    "ai-model-llama-3-3-70b-turbo" => {
      "x64" => {
        "20250221.1.0" => "833e62b949c4eb8aeccabaac4c14a8af525db30c490b2eea53b33093676c7d44",
      },
    },
    "ai-model-qwen-2-5-14b-it" => {
      "x64" => {
        "20250118.1.0" => "51a7fe8c520f39b8197c88426c8f37199bd3bd2afdae579b8877a604cd474021",
      },
    },
    "ai-model-qwq-32b-preview" => {
      "x64" => {
        "20241209.1.0" => "38ca4912134ed9b115726eff258666d68ce6df92330a3585d47494099821f9b1",
      },
    },
    "ai-model-ds-r1-qwen-32b" => {
      "x64" => {
        "20250227.1.0" => "16269ce8660413718c58b60c649042cca6cef2429f59f59e4c70bb5e951ebe74",
      },
    },
    "ai-model-ds-r1-qwen-1-5b" => {
      "x64" => {
        "20250129.1.0" => "9135a2e81fc6129d6d12bd633b5a30d4bfe2fd219ec5e370404758dda1159001",
      },
    },
    "ai-model-ms-phi-4" => {
      "x64" => {
        "20250213.1.0" => "0e998c4916c837c0992c4546404ecb51d0c5d5923f998f7cff0a9cddc5bf1689",
      },
    },
    "ai-model-mistral-small-3" => {
      "x64" => {
        "20250217.1.0" => "01ce8d1d0b7b0f717c51c26590234f4cb7971a9a5276de92b6cb4dc2c7a085e5",
      },
    },
    "kubernetes-v1_32" => {
      "x64" => {
        "20250320.1.0" => "369c7c869bba690771a1dcbbae52159defaa3fd3540f008ba6feea291e7a220a",
      },
    },
    "kubernetes-v1_33" => {
      "x64" => {
        "20250506.1.0" => "35ca03c19385227117fa6579f58c73a362970359fa9486024ca393b134a698d4",
      },
    },
    "kubernetes-v1_34" => {
      "x64" => {
        "20250828.1.0" => "3a29122a3836109df78778df24899f864bc8beff7d92d86dc4ab8b99314f520c",
      },
    },
    "kubernetes-v1_35" => {
      "x64" => {
        "20260407.1.0" => "f1a985b5b977a054cb75a0fd4437cb16394fad9777e8fe9b09a4796cc1105cdd",
        "20260508.1.0" => "343ffdc8b53863c1f553154dda37acfa653e5cc1e854161c5dc7cf12d6ce59dd",
      },
    },
    "kubernetes-v1_36" => {
      "x64" => {
        "20260508.1.0" => "821c03a5f7e7971c91b58839928a9fc799f790364048202586a1e9da8823c8c0",
      },
    },
    "gpu-ubuntu-noble" => {
      "x64" => {
        "20251017.1.0" => "b87829c6bc71718ff0dffe2948d2586ca7ff95a02dbb03f68d18ec8c223b312c",
      },
    },
  }.each_value do |archs|
    archs.each_value(&:freeze)
    archs.freeze
  end.freeze

  def sha256sum
    sum = BOOT_IMAGE_SHA256.dig(image_name, vm_host.arch, version)
    fail "Cannot download images without a SHA256 checksum in production" if !sum && Config.production?
    sum
  end

  def r2_signed_url(key)
    client = Aws::S3::Client.new(
      endpoint: Config.ubicloud_images_r2_endpoint,
      access_key_id: Config.ubicloud_images_r2_access_key,
      secret_access_key: Config.ubicloud_images_r2_secret_key,
      region: "auto",
      request_checksum_calculation: "when_required",
      response_checksum_validation: "when_required",
    )
    Aws::S3::Presigner.new(client:).presigned_url(:get_object, bucket: Config.ubicloud_images_r2_bucket_name, key:, expires_in: 60 * 60)
  end

  def minio_signed_url(key)
    client = Minio::Client.new(
      endpoint: Config.ubicloud_images_blob_storage_endpoint,
      access_key: Config.ubicloud_images_blob_storage_access_key,
      secret_key: Config.ubicloud_images_blob_storage_secret_key,
      ssl_ca_data: Config.ubicloud_images_blob_storage_certs,
    )
    client.get_presigned_url("GET", Config.ubicloud_images_bucket_name, key, 60 * 60).to_s
  end

  label def start
    register_deadline(nil, 24 * 60 * 60)

    pop "Image already exists on host" unless vm_host.boot_images_dataset.where(name: image_name, version:).empty?

    BootImage.create(
      vm_host_id: vm_host.id,
      name: image_name,
      version:,
      activated_at: nil,
      size_gib: 0,
    )
    hop_download
  end

  label def download
    daemon_name = "download_#{image_name}_#{version}"
    case sshable.cmd("common/bin/daemonizer --check :daemon_name", daemon_name:)
    when "Succeeded"
      sshable.cmd("common/bin/daemonizer --clean :daemon_name", daemon_name:)
      hop_update_available_storage_space
    when "NotStarted"
      if cancel_set?
        image.destroy
        pop "operation cancelled"
      end
      certs = download_from_blob_storage? ? Config.ubicloud_images_blob_storage_certs : nil
      params = {image_name:, url:, version:, sha256sum:, certs:, use_htcat: download_from_r2?}
      sshable.cmd("common/bin/daemonizer 'host/bin/download-boot-image' :daemon_name", daemon_name:, stdin: params.to_json)
    when "Failed"
      restarted = frame["restarted"] || 0
      if restarted < 10
        sshable.cmd("cat var/log/:daemon_name.stderr || true", daemon_name:)
        sshable.cmd("cat var/log/:daemon_name.stdout || true", daemon_name:)
        sshable.cmd("common/bin/daemonizer --clean :daemon_name", daemon_name:)
        update_stack({"restarted" => restarted + 1})
      else
        Clog.emit("Failed to download boot image", {failed_boot_image_download: [vm_host, {image_name:, version:}]})
      end
      if cancel_set? || (frame["exit_on_fail"] && restarted >= 10)
        image.destroy
        pop "operation cancelled"
      end
    end

    nap 15
  end

  label def update_available_storage_space
    image_size_bytes = sshable.cmd("stat -c %s :image_path", image_path: image.path).to_i
    fail "Downloaded boot image has zero size" unless image_size_bytes > 0
    image_size_gib = (image_size_bytes / 1024.0**3).ceil
    StorageDevice.where(vm_host_id: vm_host.id, name: "DEFAULT").update(
      available_storage_gib: Sequel[:available_storage_gib] - image_size_gib,
    )
    image.update(size_gib: image_size_gib)
    hop_activate_boot_image
  end

  label def activate_boot_image
    if cancel_set?
      image.remove_boot_image
      pop "operation cancelled"
    end

    image.update(activated_at: Time.now)
    Clog.emit("Boot image download completed", [
      image,
      boot_image_download: {
        duration: (image.activated_at - image.created_at).round(2),
        restarts: frame["restarted"] || 0,
        vm_host_ubid: vm_host.ubid,
        arch: vm_host.arch,
        location: vm_host.location.display_name,
      },
    ])
    pop({"msg" => "image downloaded", "name" => image_name, "version" => version})
  end
end
