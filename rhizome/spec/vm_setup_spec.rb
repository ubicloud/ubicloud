# frozen_string_literal: true

require_relative "../lib/vm_setup"
require "openssl"
require "base64"

RSpec.describe VmSetup do
  subject(:vs) { described_class.new("test") }

  def key_wrapping_secrets
    key_wrapping_algorithm = "aes-256-gcm"
    cipher = OpenSSL::Cipher.new(key_wrapping_algorithm)
    {
      "key" => Base64.encode64(cipher.random_key),
      "init_vector" => Base64.encode64(cipher.random_iv),
      "algorithm" => key_wrapping_algorithm,
      "auth_data" => "Ubicloud-Test-Auth"
    }
  end

  it "can halve an IPv6 network" do
    lower, upper = vs.subdivide_network(NetAddr.parse_net("2a01:4f9:2b:35b:7e40::/79"))
    expect(lower.to_s).to eq("2a01:4f9:2b:35b:7e40::/80")
    expect(upper.to_s).to eq("2a01:4f9:2b:35b:7e41::/80")
  end

  it "templates user YAML" do
    vps = instance_spy(VmPath)
    expect(vs).to receive(:vp).and_return(vps).at_least(:once)
    vs.write_user_data("some_user", "some_ssh_key")
    expect(vps).to have_received(:write_user_data) {
      expect(_1).to match(/some_user/)
      expect(_1).to match(/some_ssh_key/)
    }
  end

  describe "#setup_volume" do
    it "can setup a storage volume" do
      disk_file = "/var/storage/test/0/disk.raw"
      device_id = "some_device_id"
      spdk_vhost_sock = "/var/storage/vhost/test_0"
      vm_vhost_sock = "/var/storage/test/0/vhost.sock"
      boot_image = "ubuntu-jammy"
      size_gib = 5
      key_wrapping_secrets = {}
      data_encryption_key = {cipher: "AES-XTS", k: "123", e: "456"}

      expect(vs).to receive(:setup_disk_file).and_return(disk_file)
      expect(vs).to receive(:r).with(/setfacl.*#{disk_file}/)
      expect(vs).to receive(:setup_data_encryption_key).with(0, key_wrapping_secrets).and_return(data_encryption_key)
      expect(vs).to receive(:copy_image).with(disk_file, boot_image, size_gib, true, data_encryption_key)
      expect(vs).to receive(:setup_spdk_bdev).with(device_id, disk_file, true, data_encryption_key)
      expect(vs).to receive(:r).with(/.*rpc.py.*vhost_create_blk_controller test_0 #{device_id}/)
      expect(FileUtils).to receive(:chown).with("test", "test", disk_file)
      expect(FileUtils).to receive(:chmod).with("u=rw,g=r,o=", disk_file)
      expect(FileUtils).to receive(:chmod).with("u=rw,g=r,o=", spdk_vhost_sock)
      expect(FileUtils).to receive(:ln_s).with(spdk_vhost_sock, vm_vhost_sock)
      expect(FileUtils).to receive(:chown).with("test", "test", vm_vhost_sock)
      expect(vs).to receive(:r).with(/setfacl.*#{spdk_vhost_sock}/)

      expect(
        vs.setup_volume({"boot" => true, "size_gib" => size_gib, "device_id" => device_id},
          0, boot_image, key_wrapping_secrets)
      ).to eq(vm_vhost_sock)
    end
  end

  describe "#setup_disk_file" do
    it "can setup a disk" do
      disk_file = "/var/storage/test/0/disk.raw"
      expect(FileUtils).to receive(:touch).with(disk_file)
      expect(vs).to receive(:r).with("truncate -s 5G #{disk_file}")
      expect(
        vs.setup_disk_file({"boot" => true, "size_gib" => 5, "device_id" => "disk0"}, 0)
      ).to eq(disk_file)
    end
  end

  describe "#copy_image" do
    it "fails if requested size is too small" do
      boot_image = "ubuntu-jammy"
      image_path = "/opt/#{boot_image}.raw"
      disk_file = "/var/storage/test/disk_0.raw"
      expect(vs).to receive(:download_boot_image).and_return image_path
      expect(File).to receive(:size).with(image_path).and_return(5 * 2**30)
      expect {
        vs.copy_image(disk_file, boot_image, 2, false, nil)
      }.to raise_error RuntimeError, "Image size greater than requested disk size"
    end

    it "copies non-encrypted image" do
      boot_image = "ubuntu-jammy"
      image_path = "/opt/#{boot_image}.raw"
      disk_file = "/var/storage/test/disk_0.raw"
      expect(vs).to receive(:download_boot_image).and_return image_path
      expect(File).to receive(:size).with(image_path).and_return(2 * 2**30)
      expect(vs).to receive(:r).with(/spdk_dd.*--if #{image_path} --ob aio0 --bs=[0-9]+$/, stdin: /{.*}/)
      vs.copy_image(disk_file, boot_image, 10, false, nil)
    end

    it "copies encrypted image" do
      boot_image = "ubuntu-jammy"
      image_path = "/opt/#{boot_image}.raw"
      disk_file = "/var/storage/test/disk_0.raw"
      encryption_key = {cipher: "aes_xts", key: "key1value", key2: "key2value"}
      expect(vs).to receive(:download_boot_image).and_return image_path
      expect(File).to receive(:size).with(image_path).and_return(2 * 2**30)
      expect(vs).to receive(:r).with(/spdk_dd.*--if #{image_path} --ob crypt0 --bs=[0-9]+$/, stdin: /{.*}/)
      vs.copy_image(disk_file, boot_image, 10, true, encryption_key)
    end
  end

  describe "#download_boot_image" do
    it "can download an image" do
      expect(File).to receive(:exist?).with("/opt/ubuntu-jammy.raw").and_return(false)
      expect(File).to receive(:open) do |path, *_args|
        expect(path).to eq("/opt/ubuntu-jammy.qcow2.tmp")
      end.and_yield
      expect(vs).to receive(:r).with("curl -L10 -o /opt/ubuntu-jammy.qcow2.tmp https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img")
      expect(vs).to receive(:r).with("qemu-img convert -p -f qcow2 -O raw /opt/ubuntu-jammy.qcow2.tmp /opt/ubuntu-jammy.raw")

      vs.download_boot_image("ubuntu-jammy")
    end

    it "can use an image that's already downloaded" do
      expect(File).to receive(:exist?).with("/opt/almalinux-9.1.raw").and_return(true)
      vs.download_boot_image("almalinux-9.1")
    end
  end

  describe "#setup_spdk_bdev" do
    it "can setup a non-encrypted volume" do
      bdev = "bdev_name"
      disk_file = "/path/to/disk/file"
      expect(vs).to receive(:r).with(/.*rpc.py.*bdev_aio_create #{disk_file} #{bdev} 512$/)
      vs.setup_spdk_bdev(bdev, disk_file, false, nil)
    end

    it "can setup an encrypted volume" do
      bdev = "bdev_name"
      disk_file = "/path/to/disk/file"
      encryption_key = {cipher: "aes_xts", key: "key1value", key2: "key2value"}
      expect(vs).to receive(:r).with(/.*rpc.py.*accel_crypto_key_create -c aes_xts -k key1value -e key2value/)
      expect(vs).to receive(:r).with(/.*rpc.py.*bdev_aio_create #{disk_file} #{bdev}_aio 512$/)
      expect(vs).to receive(:r).with(/.*rpc.py.*bdev_crypto_create.*#{bdev}_aio #{bdev}$/)
      vs.setup_spdk_bdev(bdev, disk_file, true, encryption_key)
    end
  end

  describe "#setup_data_encryption_key" do
    it "can setup data encryption key" do
      key_file = "/var/storage/test/3/data_encryption_key.json"
      expect(FileUtils).to receive(:chown).with("test", "test", key_file)
      expect(FileUtils).to receive(:chmod).with("u=rw,g=,o=", key_file)
      expect(File).to receive(:open).with(key_file, "w")
      expect(vs).to receive(:sync_parent_dir).with(key_file)
      vs.setup_data_encryption_key(3, key_wrapping_secrets)
    end
  end
end
