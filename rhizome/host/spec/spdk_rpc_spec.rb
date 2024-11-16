# frozen_string_literal: true

require_relative "../lib/spdk_rpc"

RSpec.describe SpdkRpc do
  subject(:sr) {
    described_class.new("/path/to/spdk.sock", 5, 100)
  }

  describe "#bdev_aio_create" do
    it "can create an aio bdev" do
      expect(sr).to receive(:call).with("bdev_aio_create", {
        name: "name",
        filename: "filename",
        block_size: 512,
        readonly: false
      })
      sr.bdev_aio_create("name", "filename", 512)
    end
  end

  describe "#bdev_aio_delete" do
    it "can delete an aio bdev" do
      expect(sr).to receive(:call).with("bdev_aio_delete", {
        name: "name"
      })
      sr.bdev_aio_delete("name")
    end

    it "ignores exception if bdev doesn't exist and if_exists=true" do
      expect(sr).to receive(:call).with("bdev_aio_delete", {
        name: "name"
      }).and_raise SpdkRpcError.build("No such device", -19)
      sr.bdev_aio_delete("name")
    end

    it "raises exception if bdev doesn't exist and if_exists=false" do
      expect(sr).to receive(:call).with("bdev_aio_delete", {
        name: "name"
      }).and_raise SpdkRpcError.build("No such device", -19)
      expect { sr.bdev_aio_delete("name", false) }.to raise_error SpdkNotFound
    end
  end

  describe "#bdev_crypto_create" do
    it "can create an crypto bdev" do
      expect(sr).to receive(:call).with("bdev_crypto_create", {
        name: "name",
        base_bdev_name: "base",
        key_name: "key"
      })
      sr.bdev_crypto_create("name", "base", "key")
    end
  end

  describe "#bdev_crypto_delete" do
    it "can delete an crypto bdev" do
      expect(sr).to receive(:call).with("bdev_crypto_delete", {
        name: "name"
      })
      sr.bdev_crypto_delete("name")
    end

    it "ignores exception if bdev doesn't exist and if_exists=true" do
      expect(sr).to receive(:call).with("bdev_crypto_delete", {
        name: "name"
      }).and_raise SpdkRpcError.build("No such device", -19)
      sr.bdev_crypto_delete("name")
    end

    it "raises exception if bdev doesn't exist and if_exists=false" do
      expect(sr).to receive(:call).with("bdev_crypto_delete", {
        name: "name"
      }).and_raise SpdkRpcError.build("No such device", -19)
      expect { sr.bdev_crypto_delete("name", false) }.to raise_error SpdkNotFound
    end
  end

  describe "#vhost_create_blk_controller" do
    it "can create a vhost block controller" do
      expect(sr).to receive(:call).with("vhost_create_blk_controller", {
        ctrlr: "name",
        dev_name: "bdev"
      })
      sr.vhost_create_blk_controller("name", "bdev")
    end

    it "raises SpdkExists if device already exists" do
      expect(sr).to receive(:call).with("vhost_create_blk_controller", {
        ctrlr: "name",
        dev_name: "bdev"
      }).and_raise SpdkRpcError.build("File exists", -32602)
      expect { sr.vhost_create_blk_controller("name", "bdev") }.to raise_error SpdkExists
    end

    it "raises SpdkNotFound for other errors" do
      expect(sr).to receive(:call).with("vhost_create_blk_controller", {
        ctrlr: "name",
        dev_name: "bdev"
      }).and_raise SpdkRpcError.build("No such device", -32602)
      expect { sr.vhost_create_blk_controller("name", "bdev") }.to raise_error SpdkNotFound
    end
  end

  describe "#vhost_delete_controller" do
    it "can delete an vhost controller" do
      expect(sr).to receive(:call).with("vhost_delete_controller", {
        ctrlr: "name"
      })
      sr.vhost_delete_controller("name")
    end

    it "ignores exception if controller doesn't exist and if_exists=true" do
      expect(sr).to receive(:call).with("vhost_delete_controller", {
        ctrlr: "name"
      }).and_raise SpdkRpcError.build("No such device", -32602)
      sr.vhost_delete_controller("name")
    end

    it "raises exception if controller doesn't exist and if_exists=false" do
      expect(sr).to receive(:call).with("vhost_delete_controller", {
        ctrlr: "name"
      }).and_raise SpdkRpcError.build("No such device", -32602)
      expect { sr.vhost_delete_controller("name", false) }.to raise_error SpdkNotFound
    end
  end

  describe "#accel_crypto_key_create" do
    it "can create a crypto key" do
      expect(sr).to receive(:call).with("accel_crypto_key_create", {
        name: "name",
        cipher: "cipher",
        key: "key",
        key2: "key2"
      })
      sr.accel_crypto_key_create("name", "cipher", "key", "key2")
    end

    it "raises SpdkExists if key exists" do
      expect(sr).to receive(:call).with("accel_crypto_key_create", {
        name: "name",
        cipher: "cipher",
        key: "key",
        key2: "key2"
      }).and_raise SpdkRpcError.build("failed to create DEK, rc -17", -32602)
      expect {
        sr.accel_crypto_key_create("name", "cipher", "key", "key2")
      }.to raise_error SpdkExists
    end

    it "raises SpdkRpcError for other errors" do
      expect(sr).to receive(:call).with("accel_crypto_key_create", {
        name: "name",
        cipher: "cipher",
        key: "key",
        key2: "key2"
      }).and_raise SpdkRpcError.build("failed to create DEK, rc -22", -32602)
      expect {
        sr.accel_crypto_key_create("name", "cipher", "key", "key2")
      }.to raise_error SpdkRpcError, "failed to create DEK, rc -22"
    end
  end

  describe "#accel_crypto_key_destroy" do
    it "can delete an crypto key" do
      expect(sr).to receive(:call).with("accel_crypto_key_destroy", {
        key_name: "name"
      })
      sr.accel_crypto_key_destroy("name")
    end

    it "ignores exception if crypto key doesn't exist and if_exists=true" do
      expect(sr).to receive(:call).with("accel_crypto_key_destroy", {
        key_name: "name"
      }).and_raise SpdkRpcError.build("No key object found", -32602)
      sr.accel_crypto_key_destroy("name")
    end

    it "raises exception if crypto key doesn't exist and if_exists=false" do
      expect(sr).to receive(:call).with("accel_crypto_key_destroy", {
        key_name: "name"
      }).and_raise SpdkRpcError.build("No key object found", -32602)
      expect { sr.accel_crypto_key_destroy("name", false) }.to raise_error SpdkNotFound
    end
  end

  describe "#bdev_set_qos_limit" do
    it "can set qos limits" do
      expect(sr).to receive(:call).with("bdev_set_qos_limit", {
        name: "name",
        rw_ios_per_sec: 100,
        r_mbytes_per_sec: 300,
        w_mbytes_per_sec: 400
      })
      sr.bdev_set_qos_limit("name", rw_ios_per_sec: 100, r_mbytes_per_sec: 300, w_mbytes_per_sec: 400)
    end

    it "can set qos limits with only rw_ios_per_sec" do
      expect(sr).to receive(:call).with("bdev_set_qos_limit", {
        name: "name",
        rw_ios_per_sec: 100,
        r_mbytes_per_sec: 0,
        w_mbytes_per_sec: 0
      })
      sr.bdev_set_qos_limit("name", rw_ios_per_sec: 100)
    end

    it "can set qos limits with only r_mbytes_per_sec" do
      expect(sr).to receive(:call).with("bdev_set_qos_limit", {
        name: "name",
        rw_ios_per_sec: 0,
        r_mbytes_per_sec: 300,
        w_mbytes_per_sec: 0
      })
      sr.bdev_set_qos_limit("name", r_mbytes_per_sec: 300)
    end

    it "can set qos limits with only w_mbytes_per_sec" do
      expect(sr).to receive(:call).with("bdev_set_qos_limit", {
        name: "name",
        rw_ios_per_sec: 0,
        r_mbytes_per_sec: 0,
        w_mbytes_per_sec: 400
      })
      sr.bdev_set_qos_limit("name", w_mbytes_per_sec: 400)
    end
  end

  describe "#call" do
    let(:unix_socket) { instance_double(UNIXSocket) }

    before do
      allow(UNIXSocket).to receive(:new).and_return(unix_socket)
    end

    it "can call a method" do
      params = {"x" => "y"}
      expect(unix_socket).to receive(:write_nonblock)
      expect(sr).to receive(:read_response).with(unix_socket).and_return('{"result": "response"}')
      expect(unix_socket).to receive(:close)
      expect(sr.call("url", params)).to eq("response")
    end

    it "raises an exception if response is an error" do
      params = {"x" => "y"}
      response = {
        error: {
          message: "an error happened",
          code: -5
        }
      }.to_json
      expect(unix_socket).to receive(:write_nonblock)
      expect(sr).to receive(:read_response).with(unix_socket).and_return(response)
      expect { sr.call("url", params) }.to raise_error SpdkRpcError, "an error happened"
    end
  end

  describe "#read_response" do
    let(:unix_socket) { instance_double(UNIXSocket) }

    it "can read a valid response" do
      response = {a: "b", c: 1}.to_json
      expect(IO).to receive(:select).and_return(1)
      expect(unix_socket).to receive(:read_nonblock).and_return(response)
      expect(sr.read_response(unix_socket)).to eq(response)
    end

    it "throws a timeout exception if select returns nil" do
      expect(IO).to receive(:select).and_return(nil)
      expect(unix_socket).to receive(:close)
      expect { sr.read_response(unix_socket) }.to raise_error RuntimeError, "The request timed out after 5 seconds."
    end

    it "throws an exception if response exceeds the limit" do
      expect(IO).to receive(:select).and_return(1)
      expect(unix_socket).to receive(:read_nonblock).and_return("a" * 200)
      expect { sr.read_response(unix_socket) }.to raise_error RuntimeError, "Response size limit exceeded."
    end

    it "can read a multi-part valid response" do
      response = {a: "b", c: 1}.to_json
      expect(IO).to receive(:select).and_return(1, 1)
      expect(unix_socket).to receive(:read_nonblock).and_invoke(
        ->(_) { response[..5] },
        ->(_) { raise IO::EAGAINWaitReadable },
        ->(_) { response[6..] }
      )
      expect(sr.read_response(unix_socket)).to eq(response)
    end
  end

  describe "#valid_json?" do
    it "returns true for a valid json" do
      expect(sr.valid_json?({"a" => 1}.to_json)).to be(true)
    end

    it "returnf alse for an incomplete json" do
      expect(sr.valid_json?({"a" => 1}.to_json[..5])).to be(false)
    end
  end
end
