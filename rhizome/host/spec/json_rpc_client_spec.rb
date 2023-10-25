# frozen_string_literal: true

require_relative "../lib/json_rpc_client"

RSpec.describe JsonRpcClient do
  subject(:client) {
    described_class.new("/sock", 5, 100)
  }

  describe "#call" do
    let(:unix_socket) { instance_double(UNIXSocket) }

    before do
      allow(UNIXSocket).to receive(:new).and_return(unix_socket)
    end

    it "can call a method" do
      params = {"x" => "y"}
      expect(unix_socket).to receive(:write_nonblock)
      expect(client).to receive(:read_response).with(unix_socket).and_return('{"result": "response"}')
      expect(unix_socket).to receive(:close)
      expect(client.call("url", params)).to eq("response")
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
      expect(client).to receive(:read_response).with(unix_socket).and_return(response)
      expect { client.call("url", params) }.to raise_error JsonRpcError, "an error happened"
    end
  end

  describe "#read_response" do
    let(:unix_socket) { instance_double(UNIXSocket) }

    it "can read a valid response" do
      response = {a: "b", c: 1}.to_json
      expect(IO).to receive(:select).and_return(1)
      expect(unix_socket).to receive(:read_nonblock).and_return(response)
      expect(client.read_response(unix_socket)).to eq(response)
    end

    it "throws a timeout exception if select returns nil" do
      expect(IO).to receive(:select).and_return(nil)
      expect(unix_socket).to receive(:close)
      expect { client.read_response(unix_socket) }.to raise_error RuntimeError, "The request timed out after 5 seconds."
    end

    it "throws an exception if response exceeds the limit" do
      expect(IO).to receive(:select).and_return(1)
      expect(unix_socket).to receive(:read_nonblock).and_return("a" * 200)
      expect { client.read_response(unix_socket) }.to raise_error RuntimeError, "Response size limit exceeded."
    end

    it "can read a multi-part valid response" do
      response = {a: "b", c: 1}.to_json
      expect(IO).to receive(:select).and_return(1, 1)
      expect(unix_socket).to receive(:read_nonblock).and_invoke(
        ->(_) { response[..5] },
        ->(_) { raise IO::EAGAINWaitReadable },
        ->(_) { response[6..] }
      )
      expect(client.read_response(unix_socket)).to eq(response)
    end
  end

  describe "#valid_json?" do
    it "returns true for a valid json" do
      expect(client.valid_json?({"a" => 1}.to_json)).to be(true)
    end

    it "returnf alse for an incomplete json" do
      expect(client.valid_json?({"a" => 1}.to_json[..5])).to be(false)
    end
  end
end
