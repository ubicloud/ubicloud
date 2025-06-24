# frozen_string_literal: true

require_relative "../lib/storage_volume"
require "openssl"
require "base64"

RSpec.describe StorageVolume do
  subject(:unencrypted_sv) {
    params = {
      "disk_index" => 2,
      "device_id" => "xyz01",
      "encrypted" => false,
      "size_gib" => 12,
      "image" => "kubuntu"
    }
    described_class.new("test", params)
  }

  let(:encrypted_sv) {
    params = {
      "disk_index" => 2,
      "device_id" => "xyz01",
      "encrypted" => true,
      "size_gib" => 12,
      "image" => "kubuntu"
    }
    described_class.new("test", params)
  }

  let(:encrypted_vhost_sv) {
    params = {
      "disk_index" => 2,
      "device_id" => "xyz01",
      "encrypted" => true,
      "size_gib" => 12,
      "image" => "kubuntu",
      "vhost_block_backend_version" => "v0.1-5",
      "num_queues" => 4,
      "queue_size" => 128
    }
    described_class.new("test", params)
  }

  let(:unencrypted_vhost_sv) {
    params = {
      "disk_index" => 2,
      "device_id" => "xyz01",
      "encrypted" => false,
      "size_gib" => 12,
      "image" => "kubuntu",
      "vhost_block_backend_version" => "v0.1-5",
      "num_queues" => 4,
      "queue_size" => 128
    }
    described_class.new("test", params)
  }

  let(:image_path) {
    "/var/storage/images/kubuntu.raw"
  }
  let(:disk_file) {
    "/var/storage/test/2/disk.raw"
  }
  let(:rpc_client) {
    instance_double(SpdkRpc)
  }

  before do
    allow(encrypted_sv).to receive(:rpc_client).and_return(rpc_client)
    allow(unencrypted_sv).to receive(:rpc_client).and_return(rpc_client)
  end

  describe "#prep" do
    it "can prep a non-imaged unencrypted disk" do
      vol = described_class.new("test", {"disk_index" => 1, "encrypted" => false})
      expect(File).to receive(:exist?).with("/var/storage").and_return(true)
      expect(FileUtils).to receive(:mkdir_p).with("/var/storage/test/1")
      expect(FileUtils).to receive(:chown).with("test", "test", "/var/storage/test/1")
      expect(vol).to receive(:create_empty_disk_file).with(no_args)
      vol.prep(nil)
    end

    it "can prep a non-imaged encrypted disk" do
      key_wrapping_secrets = "key_wrapping_secrets"
      vol = described_class.new("test", {"disk_index" => 1, "encrypted" => true})
      expect(FileUtils).to receive(:mkdir_p).with("/var/storage/test/1")
      expect(FileUtils).to receive(:chown).with("test", "test", "/var/storage/test/1")
      expect(File).to receive(:exist?).with("/var/storage").and_return(true)
      expect(vol).to receive(:setup_data_encryption_key).with(key_wrapping_secrets)
      expect(vol).to receive(:create_empty_disk_file).with(no_args)
      vol.prep(key_wrapping_secrets)
    end

    it "fails if storage root doesn't exist" do
      dev_path = "/var/storage/devices/dev01"
      vol = described_class.new("test", {"disk_index" => 1, "encrypted" => false, "storage_device" => "dev01"})
      expect(File).to receive(:exist?).with(dev_path).and_return(false)
      expect { vol.prep(nil) }.to raise_error RuntimeError, "Storage device directory doesn't exist: #{dev_path}"
    end

    it "can prep an encrypted imaged disk" do
      encryption_key = "test_key"
      key_wrapping_secrets = "key_wrapping_secrets"
      expect(FileUtils).to receive(:mkdir_p).with("/var/storage/test/2")
      expect(FileUtils).to receive(:chown).with("test", "test", "/var/storage/test/2")
      expect(File).to receive(:exist?).with("/var/storage").and_return(true)
      expect(encrypted_sv).to receive(:verify_imaged_disk_size).with(no_args)
      expect(encrypted_sv).to receive(:setup_data_encryption_key).with(key_wrapping_secrets).and_return(encryption_key)
      expect(encrypted_sv).to receive(:create_empty_disk_file)
      expect(encrypted_sv).to receive(:encrypted_image_copy).with(encryption_key, image_path)
      encrypted_sv.prep(key_wrapping_secrets)
    end

    it "can prep an unencrypted imaged disk" do
      expect(FileUtils).to receive(:mkdir_p).with("/var/storage/test/2")
      expect(FileUtils).to receive(:chown).with("test", "test", "/var/storage/test/2")
      expect(File).to receive(:exist?).with("/var/storage").and_return(true)
      expect(unencrypted_sv).to receive(:verify_imaged_disk_size).with(no_args)
      expect(unencrypted_sv).to receive(:unencrypted_image_copy).with(no_args)
      unencrypted_sv.prep(nil)
    end

    it "can prep an encrypted imaged disk with vhost backend" do
      encryption_key = "test_key"
      key_wrapping_secrets = "key_wrapping_secrets"
      expect(FileUtils).to receive(:mkdir_p).with("/var/storage/test/2")
      expect(FileUtils).to receive(:chown).with("test", "test", "/var/storage/test/2")
      expect(File).to receive(:exist?).with("/var/storage").and_return(true)
      expect(encrypted_vhost_sv).to receive(:setup_data_encryption_key).with(key_wrapping_secrets).and_return(encryption_key)
      expect(encrypted_vhost_sv).to receive(:create_empty_disk_file)
      expect(encrypted_vhost_sv).to receive(:prep_vhost_backend).with(encryption_key, key_wrapping_secrets)
      encrypted_vhost_sv.prep(key_wrapping_secrets)
    end
  end

  describe "#start" do
    it "can start an encrypted storage volume" do
      encryption_key = "test_key"
      key_wrapping_secrets = "key_wrapping_secrets"
      expect(encrypted_sv).to receive(:read_data_encryption_key).with(key_wrapping_secrets).and_return(encryption_key)
      expect(encrypted_sv).to receive(:setup_spdk_bdev).with(encryption_key)
      expect(encrypted_sv).to receive(:set_qos_limits).with(no_args)
      expect(encrypted_sv).to receive(:setup_spdk_vhost).with(no_args)
      encrypted_sv.start(key_wrapping_secrets)
    end

    it "can start an uencrypted storage volume" do
      expect(unencrypted_sv).to receive(:setup_spdk_bdev).with(nil)
      expect(unencrypted_sv).to receive(:set_qos_limits).with(no_args)
      expect(unencrypted_sv).to receive(:setup_spdk_vhost).with(no_args)
      unencrypted_sv.start(nil)
    end

    it "retries after purging if spdk artifacts exist" do
      expect(unencrypted_sv).to receive(:setup_spdk_bdev).with(nil).and_return(nil, nil)
      expect(unencrypted_sv).to receive(:set_qos_limits).with(no_args).and_return(nil, nil)
      expect(unencrypted_sv).to receive(:setup_spdk_vhost).with(no_args).and_invoke(
        -> { raise SpdkExists.new("Device Exists", -17) },
        -> {}
      )
      expect(unencrypted_sv).to receive(:purge_spdk_artifacts)
      unencrypted_sv.start(nil)
    end

    it "doesn't retry more than once" do
      expect(unencrypted_sv).to receive(:setup_spdk_bdev).with(nil).and_return(nil, nil)
      expect(unencrypted_sv).to receive(:set_qos_limits).with(no_args).and_return(nil, nil)
      expect(unencrypted_sv).to receive(:setup_spdk_vhost).with(no_args).and_invoke(
        -> { raise SpdkExists.new("Device Exists", -17) },
        -> { raise SpdkExists.new("Device Exists", -17) }
      )
      expect(unencrypted_sv).to receive(:purge_spdk_artifacts)
      expect { unencrypted_sv.start(nil) }.to raise_error SpdkExists
    end

    it "can start an encrypted storage volume with vhost backend" do
      key_wrapping_secrets = "key_wrapping_secrets"
      expect(encrypted_vhost_sv).to receive(:vhost_backend_start).with(key_wrapping_secrets)
      encrypted_vhost_sv.start(key_wrapping_secrets)
    end
  end

  describe "#purge_spdk_artifacts" do
    it "can purge an encrypted disk" do
      expect(rpc_client).to receive(:vhost_delete_controller).with("test_2")
      expect(rpc_client).to receive(:bdev_crypto_delete).with("xyz01")
      expect(rpc_client).to receive(:bdev_aio_delete).with("xyz01_aio")
      expect(rpc_client).to receive(:accel_crypto_key_destroy).with("xyz01_key")
      expect(FileUtils).to receive(:rm_r).with("/var/storage/vhost/test_2")

      encrypted_sv.purge_spdk_artifacts
    end

    it "can purge an unencrypted disk" do
      expect(rpc_client).to receive(:vhost_delete_controller).with("test_2")
      expect(rpc_client).to receive(:bdev_aio_delete).with("xyz01")
      expect(FileUtils).to receive(:rm_r).with("/var/storage/vhost/test_2")

      unencrypted_sv.purge_spdk_artifacts
    end
  end

  describe "#setup_data_encryption_key" do
    it "can setup data encryption key" do
      key_file = "/var/storage/test/2/data_encryption_key.json"
      key_wrapping_secrets = "key_wrapping_secrets"
      expect(FileUtils).to receive(:chown).with("test", "test", key_file)
      expect(FileUtils).to receive(:chmod).with("u=rw,g=,o=", key_file)
      expect(File).to receive(:open).with(key_file, "w")
      expect(encrypted_sv).to receive(:sync_parent_dir).with(key_file)
      encrypted_sv.setup_data_encryption_key(key_wrapping_secrets)
    end
  end

  describe "#read_data_encryption_key" do
    it "can read data encryption key" do
      key_file = "/var/storage/test/2/data_encryption_key.json"
      dek = "123"
      key_wrapping_secrets = "key_wrapping_secrets"
      sek = instance_double(StorageKeyEncryption)
      expect(sek).to receive(:read_encrypted_dek).with(key_file).and_return(dek)
      expect(StorageKeyEncryption).to receive(:new).with(key_wrapping_secrets).and_return(sek)
      expect(encrypted_sv.read_data_encryption_key(key_wrapping_secrets)).to eq(dek)
    end
  end

  describe "#unencrypted_image_copy" do
    it "can copy an image to an unencrypted volume" do
      expect(unencrypted_sv).to receive(:r).with("cp --reflink=auto #{image_path} #{disk_file}")
      expect(unencrypted_sv).to receive(:r).with("truncate -s 12G #{disk_file.shellescape}")
      expect(unencrypted_sv).to receive(:set_disk_file_permissions)
      unencrypted_sv.unencrypted_image_copy
    end
  end

  describe "#encrypted_image_copy" do
    it "can copy an image to an encrypted volume" do
      encryption_key = {cipher: "aes_xts", key: "key1value", key2: "key2value"}
      expect(encrypted_sv).to receive(:r).with(/spdk_dd.*--if #{image_path} --ob crypt0 --bs=[0-9]+\s*$/, stdin: /{.*}/)
      encrypted_sv.encrypted_image_copy(encryption_key, image_path)
    end
  end

  describe "#create_ubi_writespace" do
    it "can create an unencrypted ubi writespace" do
      expect(unencrypted_sv).to receive(:create_empty_disk_file).with(disk_size_mib: 12 * 1024 + 16)
      unencrypted_sv.create_ubi_writespace(nil)
    end
  end

  describe "#create_empty_disk_file" do
    it "can create an empty disk file" do
      expect(FileUtils).to receive(:touch).with(disk_file)
      expect(File).to receive(:truncate).with(disk_file, 12288 * 1024 * 1024)
      expect(encrypted_sv).to receive(:set_disk_file_permissions)

      encrypted_sv.create_empty_disk_file
    end
  end

  describe "#set_disk_file_permissions" do
    it "can set disk file permissions" do
      expect(FileUtils).to receive(:chown).with("test", "test", disk_file)
      expect(FileUtils).to receive(:chmod).with("u=rw,g=r,o=", disk_file)
      expect(encrypted_sv).to receive(:r).with(/setfacl.*#{disk_file}/)

      encrypted_sv.set_disk_file_permissions
    end
  end

  describe "#setup_spdk_bdev" do
    it "can setup encrypted spdk bdev" do
      bdev = "xyz01"
      encryption_key = {cipher: "aes_xts", key: "key1value", key2: "key2value"}
      expect(rpc_client).to receive(:accel_crypto_key_create).with("#{bdev}_key", "aes_xts", "key1value", "key2value")
      expect(rpc_client).to receive(:bdev_aio_create).with("#{bdev}_aio", disk_file, 512)
      expect(rpc_client).to receive(:bdev_crypto_create).with(bdev, "#{bdev}_aio", "#{bdev}_key")
      encrypted_sv.setup_spdk_bdev(encryption_key)
    end

    it "can setup unencrypted spdk bdev" do
      bdev = "xyz01"
      disk_file = "/var/storage/test/2/disk.raw"
      expect(rpc_client).to receive(:bdev_aio_create).with(bdev, disk_file, 512)
      unencrypted_sv.setup_spdk_bdev(nil)
    end
  end

  describe "#set_qos_limits" do
    it "can set qos limits" do
      sv = described_class.new("test", {
        "disk_index" => 1,
        "device_id" => "xyz01",
        "max_read_mbytes_per_sec" => 200,
        "max_write_mbytes_per_sec" => 300
      })
      rpc_client = instance_double(SpdkRpc)
      allow(sv).to receive(:rpc_client).and_return(rpc_client)
      expect(rpc_client).to receive(:bdev_set_qos_limit).with(
        "xyz01", r_mbytes_per_sec: 200, w_mbytes_per_sec: 300
      )
      sv.set_qos_limits
    end

    it "doesn't set qos limits if none are provided" do
      sv = described_class.new("test", {
        "disk_index" => 1,
        "device_id" => "xyz01"
      })
      expect(sv).not_to receive(:rpc_client)
      sv.set_qos_limits
    end
  end

  describe "#setup_spdk_vhost" do
    it "can setup spdk vhost" do
      device_id = "xyz01"
      spdk_vhost_sock = "/var/storage/vhost/test_2"
      vm_vhost_sock = "/var/storage/test/2/vhost.sock"

      expect(rpc_client).to receive(:vhost_create_blk_controller).with("test_2", device_id)
      expect(FileUtils).to receive(:chmod).with("u=rw,g=r,o=", spdk_vhost_sock)
      expect(FileUtils).to receive(:ln_s).with(spdk_vhost_sock, vm_vhost_sock)
      expect(FileUtils).to receive(:chown).with("test", "test", vm_vhost_sock)
      expect(encrypted_sv).to receive(:r).with(/setfacl.*#{spdk_vhost_sock}/)

      encrypted_sv.setup_spdk_vhost
    end
  end

  describe "#verify_imaged_disk_size" do
    it "can verify imaged disk size" do
      expect(File).to receive(:size).and_return(2 * 2**30)
      encrypted_sv.verify_imaged_disk_size
    end

    it "fails if disk size is less than image file size" do
      expect(File).to receive(:size).and_return(15 * 2**30)
      expect { encrypted_sv.verify_imaged_disk_size }.to raise_error RuntimeError, "Image size greater than requested disk size"
    end
  end

  describe "#paths" do
    it "uses correct namespaced paths" do
      sv = described_class.new("vm12345", {"storage_device" => "nvme0", "disk_index" => 3})
      expect(sv.storage_root).to eq("/var/storage/devices/nvme0/vm12345")
      expect(sv.storage_dir).to eq("/var/storage/devices/nvme0/vm12345/3")
      expect(sv.disk_file).to eq("/var/storage/devices/nvme0/vm12345/3/disk.raw")
      expect(sv.data_encryption_key_path).to eq("/var/storage/devices/nvme0/vm12345/3/data_encryption_key.json")
      expect(sv.vhost_sock).to eq("/var/storage/devices/nvme0/vm12345/3/vhost.sock")
    end

    it "uses correct not-namespaced paths" do
      sv = described_class.new("vm12345", {"storage_device" => "DEFAULT", "disk_index" => 3})
      expect(sv.storage_root).to eq("/var/storage/vm12345")
      expect(sv.storage_dir).to eq("/var/storage/vm12345/3")
      expect(sv.disk_file).to eq("/var/storage/vm12345/3/disk.raw")
      expect(sv.data_encryption_key_path).to eq("/var/storage/vm12345/3/data_encryption_key.json")
      expect(sv.vhost_sock).to eq("/var/storage/vm12345/3/vhost.sock")
    end
  end

  describe "#prep_vhost_backend" do
    it "can prep vhost backend with metadata" do
      encryption_key = "encryption_key"
      key_wrapping_secrets = "key_wrapping_secrets"
      expect(encrypted_vhost_sv).to receive(:vhost_backend_create_config).with(encryption_key, key_wrapping_secrets)
      expect(encrypted_vhost_sv).to receive(:vhost_backend_create_metadata).with(key_wrapping_secrets)
      expect(encrypted_vhost_sv).to receive(:vhost_backend_create_service_file)
      encrypted_vhost_sv.prep_vhost_backend(encryption_key, key_wrapping_secrets)
    end
  end

  describe "#vhost_backend_create_config" do
    it "can create vhost backend config" do
      encryption_key = {
        key: "abcdefgh01234567abcdefgh01234567",
        key2: "abcdefgh01234567abcdefgh01234567"
      }
      algorithm = "aes-256-gcm"
      cipher = OpenSSL::Cipher.new(algorithm)
      key_wrapping_secrets = {
        "algorithm" => algorithm,
        "key" => Base64.encode64(cipher.random_key),
        "init_vector" => Base64.encode64(cipher.random_iv),
        "auth_data" => "Ubicloud-Test-Auth"
      }
      config_path = "/var/storage/test/2/vhost-backend.conf"
      f = instance_double(File)
      expect(File).to receive(:open).with(config_path, "w", 0o600, flags: File::CREAT | File::EXCL).and_yield(f)
      expect(FileUtils).to receive(:chown).with("test", "test", config_path)
      expect(f).to receive(:write).with(/image_path/)
      expect(encrypted_vhost_sv).to receive(:fsync_or_fail).with(f)
      expect(encrypted_vhost_sv).to receive(:sync_parent_dir).with(config_path)
      encrypted_vhost_sv.vhost_backend_create_config(encryption_key, key_wrapping_secrets)
    end
  end

  describe "#vhost_backend_create_metadata" do
    it "can create vhost backend metadata" do
      algorithm = "aes-256-gcm"
      cipher = OpenSSL::Cipher.new(algorithm)
      key_wrapping_secrets = {
        "algorithm" => algorithm,
        "key" => Base64.encode64(cipher.random_key),
        "init_vector" => Base64.encode64(cipher.random_iv),
        "auth_data" => "Ubicloud-Test-Auth"
      }
      metadata_path = "/var/storage/test/2/metadata"
      f = instance_double(File)
      expect(encrypted_vhost_sv).to receive(:rm_if_exists).with(metadata_path)
      expect(File).to receive(:open).with(metadata_path, "w", 0o600, flags: File::CREAT | File::EXCL).and_yield(f)
      expect(FileUtils).to receive(:chown).with("test", "test", metadata_path)
      expect(f).to receive(:truncate).with(8 * 1024 * 1024)
      expect(encrypted_vhost_sv).to receive(:sync_parent_dir).with(metadata_path)
      expect(encrypted_vhost_sv).to receive(:r).with(/.*init-metadata.* --kek \/dev\/stdin/, stdin: /.*aes256-gcm.*/)
      encrypted_vhost_sv.vhost_backend_create_metadata(key_wrapping_secrets)
    end

    it "can create vhost backend metadata for unencrypted vhost" do
      metadata_path = "/var/storage/test/2/metadata"
      f = instance_double(File)
      expect(unencrypted_vhost_sv).to receive(:write_new_file).with(metadata_path, "test").and_yield(f)
      expect(f).to receive(:truncate).with(8 * 1024 * 1024)
      expect(unencrypted_vhost_sv).to receive(:sync_parent_dir).with(metadata_path)
      expect(unencrypted_vhost_sv).to receive(:r).with(/.*init-metadata.*--config \/var\/storage\/test\/2\/vhost-backend.conf $/, stdin: "")
      unencrypted_vhost_sv.vhost_backend_create_metadata(nil)
    end
  end

  describe "#vhost_backend_create_service_file" do
    it "can create vhost backend service file for encrypted vhost" do
      service_file = "/etc/systemd/system/test-2-storage.service"
      expect(File).to receive(:write).with(service_file, /vhost-backend.conf --kek/)
      encrypted_vhost_sv.vhost_backend_create_service_file
    end

    it "can create vhost backend service file for unencrypted vhost" do
      service_file = "/etc/systemd/system/test-2-storage.service"
      expect(File).to receive(:write).with(service_file, /vhost-backend\.conf \nRestart=always/)
      unencrypted_vhost_sv.vhost_backend_create_service_file
    end
  end

  describe "#vhost_backend_start" do
    it "can start an encrypted vhost backend" do
      algorithm = "aes-256-gcm"
      cipher = OpenSSL::Cipher.new(algorithm)
      key_wrapping_secrets = {
        "algorithm" => algorithm,
        "key" => Base64.encode64(cipher.random_key),
        "init_vector" => Base64.encode64(cipher.random_iv),
        "auth_data" => "Ubicloud-Test-Auth"
      }
      kek_pipe = "/var/storage/test/2/kek.pipe"
      expect(encrypted_vhost_sv).to receive(:rm_if_exists).with(kek_pipe)
      expect(File).to receive(:mkfifo).with(kek_pipe, 0o600)
      expect(FileUtils).to receive(:chown).with("test", "test", kek_pipe)
      expect(encrypted_vhost_sv).to receive(:r).with("systemctl stop test-2-storage.service")
      expect(encrypted_vhost_sv).to receive(:r).with("systemctl start test-2-storage.service")
      expect(File).to receive(:write).with(kek_pipe, /aes256-gcm/)
      encrypted_vhost_sv.vhost_backend_start(key_wrapping_secrets)
    end

    it "can start an unencrypted vhost backend" do
      expect(unencrypted_vhost_sv).to receive(:r).with("systemctl stop test-2-storage.service")
      expect(unencrypted_vhost_sv).to receive(:r).with("systemctl start test-2-storage.service")
      unencrypted_vhost_sv.vhost_backend_start(nil)
    end
  end
end
