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
    it "can setup an unencrypted non-boot volume" do
      disk_file = "/var/storage/test/0/disk.raw"
      device_id = "some_device_id"
      size_gib = 5

      expect(vs).to receive(:create_empty_disk_file).with(disk_file, size_gib)
      expect(vs).to receive(:setup_spdk_bdev).with(device_id, disk_file, nil, false, nil)

      vs.setup_volume({"boot" => false, "size_gib" => size_gib, "device_id" => device_id, "use_ubi" => false},
        0, nil, nil)
    end

    it "can setup an unencrypted boot volume" do
      disk_file = "/var/storage/test/0/disk.raw"
      device_id = "some_device_id"
      boot_image = "ubuntu-jammy"
      image_path = "/opt/ubuntu.raw"
      size_gib = 5

      expect(vs).to receive(:download_boot_image).with(boot_image)
      expect(vs).to receive(:base_image_path).with(boot_image).and_return(image_path)
      expect(vs).to receive(:verify_boot_disk_size).with(image_path, 5)
      expect(vs).to receive(:unencrypted_image_copy).with(disk_file, image_path, size_gib)
      expect(vs).to receive(:setup_spdk_bdev).with(device_id, disk_file, nil, false, image_path)

      vs.setup_volume({"boot" => true, "size_gib" => size_gib, "device_id" => device_id, "use_ubi" => false},
        0, boot_image, nil)
    end

    it "can setup an encrypted boot volume" do
      disk_file = "/var/storage/test/0/disk.raw"
      device_id = "some_device_id"
      boot_image = "ubuntu-jammy"
      image_path = "/opt/ubuntu.raw"
      secrets = key_wrapping_secrets
      encryption_key = "key"
      size_gib = 5

      expect(vs).to receive(:setup_data_encryption_key).with(0, secrets).and_return(encryption_key)
      expect(vs).to receive(:download_boot_image).with(boot_image)
      expect(vs).to receive(:base_image_path).with(boot_image).and_return(image_path)
      expect(vs).to receive(:verify_boot_disk_size).with(image_path, 5)
      expect(vs).to receive(:encrypted_image_copy).with(disk_file, image_path, size_gib, encryption_key)
      expect(vs).to receive(:setup_spdk_bdev).with(device_id, disk_file, encryption_key, nil, image_path)

      vs.setup_volume({"boot" => true, "size_gib" => size_gib, "device_id" => device_id},
        0, boot_image, secrets)
    end
  end

  describe "#setup_spdk_vhost" do
    it "can setup spdk vhost" do
      device_id = "some_device_id"
      spdk_vhost_sock = "/var/storage/vhost/test_0"
      vm_vhost_sock = "/var/storage/test/0/vhost.sock"

      expect(vs).to receive(:r).with(/.*rpc.py.*vhost_create_blk_controller test_0 #{device_id}/)
      expect(FileUtils).to receive(:chmod).with("u=rw,g=r,o=", spdk_vhost_sock)
      expect(FileUtils).to receive(:ln_s).with(spdk_vhost_sock, vm_vhost_sock)
      expect(FileUtils).to receive(:chown).with("test", "test", vm_vhost_sock)
      expect(vs).to receive(:r).with(/setfacl.*#{spdk_vhost_sock}/)

      vs.setup_spdk_vhost(0, device_id)
    end
  end

  describe "#create_empty_disk_file" do
    it "can creat an empty disk file" do
      disk_file = "/var/storage/test/0/disk.raw"
      expect(FileUtils).to receive(:touch).with(disk_file)
      expect(vs).to receive(:r).with("truncate -s 5G #{disk_file}")
      expect(vs).to receive(:set_disk_file_permissions).with(disk_file)

      vs.create_empty_disk_file(disk_file, 5)
    end
  end

  describe "#set_disk_file_permissions" do
    it "can set disk file permissions" do
      disk_file = "/var/storage/test/0/disk.raw"
      expect(FileUtils).to receive(:chown).with("test", "test", disk_file)
      expect(FileUtils).to receive(:chmod).with("u=rw,g=r,o=", disk_file)
      expect(vs).to receive(:r).with(/setfacl.*#{disk_file}/)

      vs.set_disk_file_permissions(disk_file)
    end
  end

  describe "#verify_boot_disk_size" do
    it "can verify boot disk size" do
      image_path = "/opt/image"
      expect(File).to receive(:size).and_return(2 * 2**30)
      vs.verify_boot_disk_size(image_path, 5)
    end

    it "fails if disk size is less than image file size" do
      image_path = "/opt/image"
      expect(File).to receive(:size).and_return(2 * 2**30)
      expect { vs.verify_boot_disk_size(image_path, 1) }.to raise_error RuntimeError, "Image size greater than requested disk size"
    end
  end

  describe "#encrypted_image_copy" do
    it "can copy an encrypted image" do
      image_path = "/opt/ubuntu.raw"
      disk_file = "/var/storage/test/disk_0.raw"
      encryption_key = {cipher: "aes_xts", key: "key1value", key2: "key2value"}
      expect(vs).to receive(:create_empty_disk_file).with(disk_file, 10)
      expect(vs).to receive(:r).with(/spdk_dd.*--if #{image_path} --ob crypt0 --bs=[0-9]+$/, stdin: /{.*}/)
      vs.encrypted_image_copy(disk_file, image_path, 10, encryption_key)
    end
  end

  describe "#unencrypted_image_copy" do
    it "can copy an unencrypted image" do
      image_path = "/opt/ubuntu.raw"
      disk_file = "/var/storage/test/disk_0.raw"
      expect(vs).to receive(:r).with("cp --reflink=auto #{image_path} #{disk_file}")
      expect(vs).to receive(:r).with("truncate -s 10G #{disk_file.shellescape}")
      expect(vs).to receive(:set_disk_file_permissions).with(disk_file)
      vs.unencrypted_image_copy(disk_file, image_path, 10)
    end
  end

  describe "#download_boot_image" do
    it "can download an image" do
      expect(File).to receive(:exist?).with("/var/storage/images/ubuntu-jammy.raw").and_return(false)
      expect(File).to receive(:open) do |path, *_args|
        expect(path).to eq("/tmp/ubuntu-jammy.img.tmp")
      end.and_yield
      expect(FileUtils).to receive(:mkdir_p).with("/var/storage/images/")
      expect(vs).to receive(:r).with("curl -L10 -o /tmp/ubuntu-jammy.img.tmp https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img")
      expect(vs).to receive(:r).with("qemu-img convert -p -f qcow2 -O raw /tmp/ubuntu-jammy.img.tmp /var/storage/images/ubuntu-jammy.raw")
      expect(FileUtils).to receive(:rm_r).with("/tmp/ubuntu-jammy.img.tmp")

      vs.download_boot_image("ubuntu-jammy")
    end

    it "can download image with custom URL that has query params using azcopy" do
      expect(File).to receive(:exist?).with("/var/storage/images/github-ubuntu-2204.raw").and_return(false)
      expect(File).to receive(:open) do |path, *_args|
        expect(path).to eq("/tmp/github-ubuntu-2204.vhd.tmp")
      end.and_yield
      expect(FileUtils).to receive(:mkdir_p).with("/var/storage/images/")
      expect(vs).to receive(:r).with("which azcopy")
      expect(vs).to receive(:r).with("AZCOPY_CONCURRENCY_VALUE=5 azcopy copy https://images.blob.core.windows.net/images/ubuntu2204.vhd\\?sp\\=r\\&st\\=2023-09-05T22:44:05Z\\&se\\=2023-10-07T06:44:05 /tmp/github-ubuntu-2204.vhd.tmp")
      expect(vs).to receive(:r).with("qemu-img convert -p -f vpc -O raw /tmp/github-ubuntu-2204.vhd.tmp /var/storage/images/github-ubuntu-2204.raw")
      expect(FileUtils).to receive(:rm_r).with("/tmp/github-ubuntu-2204.vhd.tmp")

      vs.download_boot_image("github-ubuntu-2204", custom_url: "https://images.blob.core.windows.net/images/ubuntu2204.vhd?sp=r&st=2023-09-05T22:44:05Z&se=2023-10-07T06:44:05")
    end

    it "can use an image that's already downloaded" do
      expect(File).to receive(:exist?).with("/var/storage/images/almalinux-9.1.raw").and_return(true)
      vs.download_boot_image("almalinux-9.1")
    end

    it "fails if custom_url not provided for custom image" do
      expect(File).to receive(:exist?).with("/var/storage/images/github-ubuntu-2204.raw").and_return(false)
      expect { vs.download_boot_image("github-ubuntu-2204") }.to raise_error RuntimeError, "Must provide custom_url for github-ubuntu-2204 image"
    end

    it "fails if initial image has unsupported format" do
      expect(File).to receive(:exist?).with("/var/storage/images/github-ubuntu-2204.raw").and_return(false)
      expect(FileUtils).to receive(:mkdir_p).with("/var/storage/images/")
      expect { vs.download_boot_image("github-ubuntu-2204", custom_url: "https://example.com/ubuntu.iso") }.to raise_error RuntimeError, "Unsupported boot_image format: .iso"
    end
  end

  describe "#setup_spdk_bdev" do
    it "can setup a non-encrypted volume" do
      bdev = "bdev_name"
      disk_file = "/path/to/disk/file"
      expect(vs).to receive(:r).with(/.*rpc.py.*bdev_aio_create #{disk_file} #{bdev} 512$/)
      vs.setup_spdk_bdev(bdev, disk_file, nil, false, nil)
    end

    it "can setup an encrypted volume" do
      bdev = "bdev_name"
      disk_file = "/path/to/disk/file"
      encryption_key = {cipher: "aes_xts", key: "key1value", key2: "key2value"}
      expect(vs).to receive(:r).with(/.*rpc.py.*accel_crypto_key_create -c aes_xts -k key1value -e key2value/)
      expect(vs).to receive(:r).with(/.*rpc.py.*bdev_aio_create #{disk_file} #{bdev}_aio 512$/)
      expect(vs).to receive(:r).with(/.*rpc.py.*bdev_crypto_create.*#{bdev}_aio #{bdev}$/)
      vs.setup_spdk_bdev(bdev, disk_file, encryption_key, false, nil)
    end

    it "can setup a volume using ubi" do
      bdev = "bdev_name"
      disk_file = "/path/to/disk/file"
      image_path = "/var/storage/images/xyz.raw"
      expect(vs).to receive(:r).with(/.*rpc.py.*bdev_aio_create #{disk_file} #{bdev}_base 512$/)
      expect(vs).to receive(:r).with(/.*rpc.py.*bdev_ubi_create -n #{bdev} -b #{bdev}_base -i #{image_path} -z 1$/)
      vs.setup_spdk_bdev(bdev, disk_file, nil, true, image_path)
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

  describe "#purge_storage" do
    it "can purge storage" do
      rpc_py = "/opt/spdk/scripts/rpc.py -s /home/spdk/spdk.sock"
      params = JSON.generate({
        storage_volumes: [
          {
            boot: true,
            size_gib: 20,
            device_id: "test_0",
            disk_index: 0,
            encrypted: false
          },
          {
            boot: false,
            size_gib: 20,
            device_id: "test_1",
            disk_index: 1,
            encrypted: true
          }
        ]
      })

      expect(File).to receive(:exist?).with("/var/storage/test").and_return(true)
      expect(File).to receive(:read).with("/vm/test/prep.json").and_return(params)

      # delete the unencrypted volume
      expect(vs).to receive(:r).with("#{rpc_py} vhost_delete_controller test_0")
      expect(vs).to receive(:r).with("#{rpc_py} bdev_aio_delete test_0")
      expect(FileUtils).to receive(:rm_r).with("/var/storage/vhost/test_0")

      # delete the encrypted volume
      expect(vs).to receive(:r).with("#{rpc_py} vhost_delete_controller test_1")
      expect(vs).to receive(:r).with("#{rpc_py} bdev_crypto_delete test_1")
      expect(vs).to receive(:r).with("#{rpc_py} bdev_aio_delete test_1_aio")
      expect(vs).to receive(:r).with("#{rpc_py} accel_crypto_key_destroy -n test_1_key")
      expect(FileUtils).to receive(:rm_r).with("/var/storage/vhost/test_1")

      expect(FileUtils).to receive(:rm_r).with("/var/storage/test")

      vs.purge_storage
    end

    it "exits silently if storage hasn't been created yet" do
      expect(File).to receive(:exist?).with("/var/storage/test").and_return(false)
      vs.purge_storage
    end
  end

  describe "#purge" do
    it "can purge" do
      expect(vs).to receive(:r).with("ip netns del test")
      expect(FileUtils).to receive(:rm_f).with("/etc/systemd/system/test.service")
      expect(FileUtils).to receive(:rm_f).with("/etc/systemd/system/test-dnsmasq.service")
      expect(vs).to receive(:r).with("systemctl daemon-reload")
      expect(vs).to receive(:purge_storage)
      expect(vs).to receive(:unmount_hugepages)
      expect(vs).to receive(:r).with("deluser --remove-home test")
      expect(IO).to receive(:popen).with(["systemd-escape", "test.service"]).and_return("test.service")

      vs.purge
    end
  end

  describe "#unmount_hugepages" do
    it "can unmount hugepages" do
      expect(vs).to receive(:r).with("umount /vm/test/hugepages")
      vs.unmount_hugepages
    end

    it "exits silently if hugepages isn't mounted" do
      expect(vs).to receive(:r).with("umount /vm/test/hugepages").and_raise(CommandFail.new("", "", "/vm/test/hugepages: no mount point specified."))
      vs.unmount_hugepages
    end

    it "fails if umount fails with an unexpected error" do
      expect(vs).to receive(:r).with("umount /vm/test/hugepages").and_raise(CommandFail.new("", "", "/vm/test/hugepages: wait, what?"))
      expect { vs.unmount_hugepages }.to raise_error CommandFail
    end
  end

  describe "#recreate_unpersisted" do
    it "can recreate unpersisted state" do
      storage_volumes = [
        {"boot" => true, "size_gib" => 20, "device_id" => "test_0", "disk_index" => 0, "encrypted" => false, "use_ubi" => false},
        {"boot" => false, "size_gib" => 20, "device_id" => "test_1", "disk_index" => 1, "encrypted" => true, "use_ubi" => true}
      ]
      storage_secrets = {
        "test_1" => "storage_secrets"
      }
      boot_image = "xyz"
      image_path = "/var/storage/images/xyz.raw"

      expect(vs).to receive(:setup_networking).with(true, "gua", "ip4", "local_ip4", "nics", false)

      allow(vs).to receive(:base_image_path).with(boot_image).and_return(image_path)
      expect(vs).to receive(:setup_spdk_bdev).with("test_0", "/var/storage/test/0/disk.raw", nil, false, image_path)
      expect(vs).to receive(:setup_spdk_vhost).with(0, "test_0")

      expect(vs).to receive(:read_data_encryption_key).with(1, "storage_secrets").and_return("dek")
      expect(vs).to receive(:setup_spdk_bdev).with("test_1", "/var/storage/test/1/disk.raw", "dek", true, image_path)
      expect(vs).to receive(:setup_spdk_vhost).with(1, "test_1")

      expect(vs).to receive(:hugepages).with(4)

      vs.recreate_unpersisted("gua", "ip4", "local_ip4", "nics", 4, false, storage_volumes, storage_secrets, boot_image)
    end
  end

  describe "#setup_networking" do
    it "can setup networking" do
      vps = instance_spy(VmPath)
      expect(vs).to receive(:vp).and_return(vps).at_least(:once)

      gua = "fddf:53d2:4c89:2305:46a0::"
      guest_ephemeral = NetAddr.parse_net("fddf:53d2:4c89:2305::/65")
      clover_ephemeral = NetAddr.parse_net("fddf:53d2:4c89:2305:8000::/65")
      ip4 = "192.168.1.100"

      expect(vs).to receive(:interfaces).with([])
      expect(vs).to receive(:setup_veths_6) {
        expect(_1.to_s).to eq(guest_ephemeral.to_s)
        expect(_2.to_s).to eq(clover_ephemeral.to_s)
        expect(_3).to eq(gua)
        expect(_4).to be(false)
      }
      expect(vs).to receive(:setup_taps_6).with(gua, [])
      expect(vs).to receive(:routes4).with(ip4, "local_ip4", [])
      expect(vs).to receive(:write_nat4_config).with(ip4, [])
      expect(vs).to receive(:apply_nat4_rules)
      expect(vs).to receive(:forwarding)

      expect(vps).to receive(:write_guest_ephemeral).with(guest_ephemeral.to_s)
      expect(vps).to receive(:write_clover_ephemeral).with(clover_ephemeral.to_s)

      vs.setup_networking(false, gua, ip4, "local_ip4", [], false)
    end

    it "can setup networking for empty ip4" do
      gua = "fddf:53d2:4c89:2305:46a0::"
      expect(vs).to receive(:interfaces).with([])
      expect(vs).to receive(:setup_veths_6)
      expect(vs).to receive(:setup_taps_6).with(gua, [])
      expect(vs).to receive(:routes4).with(nil, "local_ip4", [])
      expect(vs).to receive(:forwarding)

      vs.setup_networking(true, gua, "", "local_ip4", [], false)
    end
  end

  describe "#hugepages" do
    it "can setup hugepages" do
      expect(FileUtils).to receive(:mkdir_p).with("/vm/test/hugepages")
      expect(FileUtils).to receive(:chown).with("test", "test", "/vm/test/hugepages")
      expect(vs).to receive(:r).with("mount -t hugetlbfs -o uid=test,size=2G nodev /vm/test/hugepages")
      vs.hugepages(2)
    end
  end
end
