# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::DownloadBootImage do
  subject(:dbi) { described_class.new(Strand.new(stack: [{"image_name" => "my-image", "custom_url" => "https://example.com/my-image.raw", "version" => "20230303"}])) }

  let(:dbi_without_version) { described_class.new(Strand.new(stack: [{"image_name" => "my-image", "custom_url" => "https://example.com/my-image.raw"}])) }
  let(:dbi_with_version_nil) { described_class.new(Strand.new(stack: [{"image_name" => "my-image", "version" => nil, "custom_url" => "https://example.com/my-image.raw"}])) }

  let(:sshable) { vm_host.sshable }
  let(:vm_host) { create_vm_host }

  before do
    allow(dbi).to receive_messages(sshable: sshable, vm_host: vm_host)
    allow(dbi_without_version).to receive_messages(sshable: sshable, vm_host: vm_host)
  end

  describe "#start" do
    it "creates database record and hops" do
      expect { dbi.start }.to hop("download")
      expect(BootImage.where(vm_host_id: vm_host.id, name: "my-image", version: "20230303").count).to eq(1)
    end

    it "exits if image already exists" do
      BootImage.create_with_id(vm_host, vm_host_id: vm_host.id, name: "my-image", version: "20230303", size_gib: 3)
      expect { dbi.start }.to exit({"msg" => "Image already exists on host"})
    end

    it "fails if image unknown" do
      expect { dbi_without_version.start }.to raise_error RuntimeError, "Unknown boot image: my-image"
    end

    it "fails if version is nil" do
      expect { dbi_with_version_nil.start }.to raise_error RuntimeError, "Version can not be passed as nil"
    end
  end

  describe "#default_boot_image_version" do
    it "returns the version for the default image" do
      expect(dbi.default_boot_image_version("ubuntu-noble")).to eq(Config.ubuntu_noble_version)
    end

    it "escapes the image name" do
      expect(Config).to receive(:kubernetes_v1_32_version).and_return("version")
      expect(dbi.default_boot_image_version("kubernetes-v1_32")).to eq("version")
    end

    it "fails for unknown images" do
      expect { dbi.default_boot_image_version("unknown-image") }.to raise_error RuntimeError, "Unknown boot image: unknown-image"
    end
  end

  describe "#url" do
    it "returns custom_url if it's provided" do
      expect(dbi.url).to eq("https://example.com/my-image.raw")
    end

    it "returns presigned URL if custom_url is not provided" do
      expect(dbi).to receive(:frame).and_return({"image_name" => "github-ubuntu-2204", "version" => Config.github_ubuntu_2204_version}).at_least(:once)
      expect(Minio::Client).to receive(:new).and_return(instance_double(Minio::Client, get_presigned_url: "https://minio.example.com/my-image.raw"))
      expect(dbi.url).to eq("https://minio.example.com/my-image.raw")
    end

    it "returns URL for x64 ubuntu-noble image" do
      expect(dbi).to receive(:frame).and_return({"image_name" => "ubuntu-noble", "version" => "20240523.1"}).at_least(:once)
      expect(dbi.url).to eq("https://cloud-images.ubuntu.com/releases/noble/release-20240523.1/ubuntu-24.04-server-cloudimg-amd64.img")
    end

    it "returns URL for arm64 ubuntu-noble image" do
      expect(dbi).to receive(:frame).and_return({"image_name" => "ubuntu-noble", "version" => "20240523.1"}).at_least(:once)
      vm_host.update(arch: "arm64")
      expect(dbi.url).to eq("https://cloud-images.ubuntu.com/releases/noble/release-20240523.1/ubuntu-24.04-server-cloudimg-arm64.img")
    end

    it "returns URL for x64 ubuntu-jammy image" do
      expect(dbi).to receive(:frame).and_return({"image_name" => "ubuntu-jammy", "version" => "20240319"}).at_least(:once)
      expect(dbi.url).to eq("https://cloud-images.ubuntu.com/releases/jammy/release-20240319/ubuntu-22.04-server-cloudimg-amd64.img")
    end

    it "returns URL for arm64 ubuntu-jammy image" do
      expect(dbi).to receive(:frame).and_return({"image_name" => "ubuntu-jammy", "version" => "20240319"}).at_least(:once)
      vm_host.update(arch: "arm64")
      expect(dbi.url).to eq("https://cloud-images.ubuntu.com/releases/jammy/release-20240319/ubuntu-22.04-server-cloudimg-arm64.img")
    end

    it "returns URL for arm64 debian-12 image" do
      expect(dbi).to receive(:frame).and_return({"image_name" => "debian-12", "version" => "20241004-1890"}).at_least(:once)
      vm_host.arch = "arm64"
      expect(dbi.url).to eq("https://cloud.debian.org/images/cloud/bookworm/20241004-1890/debian-12-genericcloud-arm64-20241004-1890.raw")
    end

    it "returns URL for x64 debian-12 image" do
      expect(dbi).to receive(:frame).and_return({"image_name" => "debian-12", "version" => "20241004-1890"}).at_least(:once)
      vm_host.arch = "x64"
      expect(dbi.url).to eq("https://cloud.debian.org/images/cloud/bookworm/20241004-1890/debian-12-genericcloud-amd64-20241004-1890.raw")
    end

    it "returns URL for x64 almalinux-9 image" do
      expect(dbi).to receive(:frame).and_return({"image_name" => "almalinux-9", "version" => "9.5-20241120"}).at_least(:once)
      expect(dbi.url).to eq("https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-9.5-20241120.x86_64.qcow2")
    end

    it "returns URL for arm64 almalinux-9 image" do
      expect(dbi).to receive(:frame).and_return({"image_name" => "almalinux-9", "version" => "9.5-20241120"}).at_least(:once)
      vm_host.update(arch: "arm64")

      expect(dbi.url).to eq("https://repo.almalinux.org/almalinux/9/cloud/aarch64/images/AlmaLinux-9-GenericCloud-9.5-20241120.aarch64.qcow2")
    end

    it "returns URL for ai model image" do
      expect(dbi).to receive(:frame).and_return({"image_name" => "ai-model-test-model", "version" => "20240924.1.0"}).at_least(:once)

      mcl = instance_double(Minio::Client)
      expect(Minio::Client).to receive(:new).and_return(mcl)
      expect(mcl).to receive(:get_presigned_url).with("GET", Config.ubicloud_images_bucket_name, "ai-model-test-model-20240924.1.0.raw", 60 * 60).and_return("https://minio.example.com/ubicloud-image/ai-model-test-model-20240924.1.0.raw")
      expect(dbi.url).to eq("https://minio.example.com/ubicloud-image/ai-model-test-model-20240924.1.0.raw")
    end

    it "fails if image name is unknown" do
      dbi = described_class.new(Strand.new(stack: [{"image_name" => "unknown", "custom_url" => nil, "version" => "20231113"}]))
      expect { dbi.url }.to raise_error RuntimeError, "Unknown image name: unknown"
    end
  end

  describe "#download" do
    it "starts to download image if it's not started yet" do
      params_json = {
        "image_name" => "my-image",
        "url" => "https://example.com/my-image.raw",
        "version" => "20230303",
        "sha256sum" => nil,
        "certs" => nil,
        "use_htcat" => false
      }.to_json
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check download_my-image_20230303").and_return("NotStarted")
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer 'host/bin/download-boot-image' download_my-image_20230303", stdin: params_json)
      expect { dbi.download }.to nap(15)
    end

    it "generates MinIO presigned URL for github-runners images if a custom_url not provided" do
      params_json = {
        "image_name" => "github-ubuntu-2204",
        "url" => "https://minio.example.com/my-image.raw",
        "version" => Config.github_ubuntu_2204_version,
        "sha256sum" => "sha256_sum",
        "certs" => "certs",
        "use_htcat" => false
      }.to_json
      expect(dbi).to receive(:frame).and_return({"image_name" => "github-ubuntu-2204", "version" => Config.github_ubuntu_2204_version}).at_least(:once)
      expect(Minio::Client).to receive(:new).and_return(instance_double(Minio::Client, get_presigned_url: "https://minio.example.com/my-image.raw"))
      expect(Config).to receive(:ubicloud_images_blob_storage_certs).and_return("certs").at_least(:once)
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check download_github-ubuntu-2204_#{Config.github_ubuntu_2204_version}").and_return("NotStarted")
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer 'host/bin/download-boot-image' download_github-ubuntu-2204_#{Config.github_ubuntu_2204_version}", stdin: params_json)
      expect(dbi).to receive(:sha256sum).and_return("sha256_sum")
      expect { dbi.download }.to nap(15)
    end

    it "generates R2 presigned URL for github-runners images if a custom_url not provided" do
      allow(Config).to receive(:ubicloud_images_r2_bucket_name).and_return("images-bucket")
      url_presigner = instance_double(Aws::S3::Presigner)
      s3_client = instance_double(Aws::S3::Client)
      allow(Aws::S3::Presigner).to receive(:new).with(client: s3_client).and_return(url_presigner)
      allow(Aws::S3::Client).to receive(:new).and_return(s3_client)
      expect(url_presigner).to receive(:presigned_url).with(:get_object, hash_including(bucket: "images-bucket", key: "github-ubuntu-2204-x64-#{Config.github_ubuntu_2204_version}.raw")).and_return("https://r2.example.com/my-image.raw")
      params_json = {
        "image_name" => "github-ubuntu-2204",
        "url" => "https://r2.example.com/my-image.raw",
        "version" => Config.github_ubuntu_2204_version,
        "sha256sum" => "sha256_sum",
        "certs" => nil,
        "use_htcat" => true
      }.to_json
      expect(dbi).to receive(:frame).and_return({"image_name" => "github-ubuntu-2204", "version" => Config.github_ubuntu_2204_version, "download_r2" => true}).at_least(:once)
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check download_github-ubuntu-2204_#{Config.github_ubuntu_2204_version}").and_return("NotStarted")
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer 'host/bin/download-boot-image' download_github-ubuntu-2204_#{Config.github_ubuntu_2204_version}", stdin: params_json)
      expect(dbi).to receive(:sha256sum).and_return("sha256_sum")
      expect { dbi.download }.to nap(15)
    end

    it "waits manual intervation if it's failed in production" do
      expect(Config).to receive(:production?).and_return(true)
      expect(sshable).to receive(:cmd).with("cat var/log/download_my-image_20230303.stderr || true")
      expect(sshable).to receive(:cmd).with("cat var/log/download_my-image_20230303.stdout || true")
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check download_my-image_20230303").and_return("Failed")
      expect { dbi.download }.to raise_error RuntimeError, "Failed to download 'my-image' image on VmHost[\"#{vm_host.ubid}\"]"
    end

    it "retries downloading image if it is failed somewhere other than production" do
      expect(Config).to receive(:production?).and_return(false)
      expect(sshable).to receive(:cmd).with("cat var/log/download_my-image_20230303.stderr || true")
      expect(sshable).to receive(:cmd).with("cat var/log/download_my-image_20230303.stdout || true")
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check download_my-image_20230303").and_return("Failed")
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --clean download_my-image_20230303")
      expect { dbi.download }.to raise_error RuntimeError, "Failed to download 'my-image' image on VmHost[\"#{vm_host.ubid}\"]"
    end

    it "waits for the download to complete" do
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check download_my-image_20230303").and_return("InProgess")
      expect { dbi.download }.to nap(15)
    end

    it "hops if it's succeeded" do
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check download_my-image_20230303").and_return("Succeeded")
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --clean download_my-image_20230303")
      expect { dbi.download }.to hop("update_available_storage_space")
    end
  end

  describe "#update_available_storage_space" do
    it "updates available storage space" do
      bi = BootImage.create(vm_host_id: vm_host.id, name: "my-image", version: "20230303", size_gib: 0)
      sd = StorageDevice.create(
        vm_host_id: vm_host.id,
        name: "DEFAULT",
        total_storage_gib: 50,
        available_storage_gib: 35,
        enabled: true
      )
      expect(sshable).to receive(:cmd).with("stat -c %s /var/storage/images/my-image-20230303.raw").and_return("2361393152")
      expect { dbi.update_available_storage_space }.to hop("activate_boot_image")
      expect(sd.reload.available_storage_gib).to eq(32)
      expect(bi.reload.size_gib).to eq(3)
    end

    it "checks the correct path if version is nil" do
      BootImage.create(vm_host_id: vm_host.id, name: "my-image", version: nil, size_gib: 0)
      dbi = described_class.new(Strand.new(stack: [{"image_name" => "my-image", "custom_url" => "https://example.com/my-image.raw", "version" => nil}]))
      allow(dbi).to receive_messages(sshable: sshable, vm_host: vm_host)
      sd = StorageDevice.create(
        vm_host_id: vm_host.id,
        name: "DEFAULT",
        total_storage_gib: 50,
        available_storage_gib: 35,
        enabled: true
      )
      expect(sshable).to receive(:cmd).with("stat -c %s /var/storage/images/my-image.raw").and_return("2361393152")
      expect { dbi.update_available_storage_space }.to hop("activate_boot_image")
      expect(sd.reload.available_storage_gib).to eq(32)
    end
  end

  describe "#activate_boot_image" do
    it "activates the boot image" do
      dataset = instance_double(Sequel::Dataset)
      expect(BootImage).to receive(:where).with(vm_host_id: vm_host.id, name: "my-image", version: "20230303").and_return(dataset)
      expect(dataset).to receive(:update) do |args|
        expect(args[:activated_at]).to be <= Time.now
      end
      expect { dbi.activate_boot_image }.to exit({"msg" => "image downloaded", "name" => "my-image", "version" => "20230303"})
    end
  end
end
