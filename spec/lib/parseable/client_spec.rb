# frozen_string_literal: true

RSpec.describe Parseable::Client do
  let(:endpoint) { "https://parseable.example.com" }
  let(:ssl_ca_data) { Util.create_root_certificate(common_name: "test CA", duration: 60 * 60 * 24 * 365).first }
  let(:client) { described_class.new(endpoint:, ssl_ca_data:, username: "admin", password: "secret") }

  describe "#initialize" do
    it "creates an Excon client with given ssl_ca_data, endpoint, username, and password" do
      client = described_class.new(endpoint: "https://example.com", ssl_ca_data:, username: "admin", password: "secret")
      expect(client.instance_variable_get(:@endpoint)).to eq("https://example.com")
      expect(client.instance_variable_get(:@username)).to eq("admin")
      expect(client.instance_variable_get(:@password)).to eq("secret")
    end

    it "creates an Excon client when not supplied with ssl_ca_data" do
      client = described_class.new(endpoint: "https://example.com", username: "admin2", password: "foobar")
      expect(client.instance_variable_get(:@endpoint)).to eq("https://example.com")
      expect(client.instance_variable_get(:@username)).to eq("admin2")
      expect(client.instance_variable_get(:@password)).to eq("foobar")
    end
  end

  describe "#healthy?" do
    it "returns true when liveness endpoint returns 200" do
      stub_request(:get, "#{endpoint}/api/v1/liveness").to_return(status: 200)
      expect(client.healthy?).to be true
    end

    it "raises Client::Error when liveness endpoint returns non-200" do
      stub_request(:get, "#{endpoint}/api/v1/liveness").to_return(status: 503)
      expect { client.healthy? }.to raise_error Parseable::Client::Error
    end
  end

  describe "#create_stream" do
    it "sends a PUT request for the stream" do
      stub_request(:put, "#{endpoint}/api/v1/logstream/mystream").to_return(status: 200)
      expect { client.create_stream("mystream") }.not_to raise_error
    end

    it "raises Client::Error on non-success status" do
      stub_request(:put, "#{endpoint}/api/v1/logstream/mystream").to_return(status: 500)
      expect { client.create_stream("mystream") }.to raise_error Parseable::Client::Error, /500/
    end
  end

  describe "#emit" do
    it "sends a gzip-encoded POST with JSON body" do
      stub = stub_request(:post, "#{endpoint}/api/v1/logstream/mystream")
        .with(headers: {"Content-Encoding" => "gzip", "Content-Type" => "application/json"})
        .to_return(status: 200)
      client.emit("mystream", [{msg: "hello"}])
      expect(stub).to have_been_requested
    end

    it "wraps a single event in an array" do
      stub_request(:post, "#{endpoint}/api/v1/logstream/mystream")
        .with(headers: {"Content-Encoding" => "gzip"})
        .to_return(status: 200)
      client.emit("mystream", {msg: "hello"})
      body = WebMock::RequestRegistry.instance.requested_signatures.hash.keys.last.body
      expect(JSON.parse(Zlib::GzipReader.new(StringIO.new(body)).read)).to eq([{"msg" => "hello"}])
    end
  end

  describe "#query" do
    let(:start_time) { "2026-01-01T00:00:00Z" }
    let(:end_time) { "2026-01-02T00:00:00Z" }

    it "sends a POST and returns parsed JSON" do
      result = [{"col" => "val"}]
      stub_request(:post, "#{endpoint}/api/v1/query").to_return(status: 200, body: result.to_json)
      expect(client.query("SELECT 1", start_time:, end_time:)).to eq(result)
    end

    it "raises Client::Error on non-success status" do
      stub_request(:post, "#{endpoint}/api/v1/query").to_return(status: 400)
      expect { client.query("bad sql", start_time:, end_time:) }.to raise_error Parseable::Client::Error
    end
  end

  describe "authentication" do
    it "sends Basic auth header when username and password are provided" do
      expected_auth = "Basic #{Base64.strict_encode64("admin:secret")}"
      stub_request(:get, "#{endpoint}/api/v1/liveness")
        .with(headers: {"Authorization" => expected_auth})
        .to_return(status: 200)
      expect(client.healthy?).to be true
    end

    it "does not send Authorization header when no credentials are provided" do
      unauthenticated = described_class.new(endpoint:, ssl_ca_data:)
      stub_request(:get, "#{endpoint}/api/v1/liveness").to_return(status: 200)
      expect(unauthenticated.healthy?).to be true
    end
  end
end
