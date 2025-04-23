# frozen_string_literal: true

require "spec_helper"

RSpec.describe VictoriaMetrics::Client do
  let(:endpoint) { "http://localhost:8428" }
  let(:client) { described_class.new(endpoint: endpoint) }

  describe "#initialize" do
    it "creates a client with the given endpoint" do
      expect(client.instance_variable_get(:@endpoint)).to eq(endpoint)
    end

    it "creates a client with SSL configuration" do
      ssl_ca_file_data = "-----BEGIN CERTIFICATE-----\nMOCK_CERT\n-----END CERTIFICATE-----"
      client = described_class.new(endpoint: endpoint, ssl_ca_file_data: ssl_ca_file_data)

      expect(client.instance_variable_get(:@client)).to be_a(Excon::Connection)
      expect(client.instance_variable_get(:@client).data[:ssl_ca_file]).to include("ca_bundles")
    end

    it "does not write the ca_bundle file if it exists" do
      ssl_ca_file_data = "-----BEGIN CERTIFICATE-----\nMOCK_CERT\n-----END CERTIFICATE-----"
      ssl_ca_file_name = Digest::SHA256.hexdigest(ssl_ca_file_data)
      ca_bundle_filename = File.join(Dir.pwd, "var", "ca_bundles", ssl_ca_file_name + ".crt")
      expect(File).to receive(:exist?).with(ca_bundle_filename).and_return(true)
      expect(File).not_to receive(:write)
      described_class.new(endpoint: endpoint, ssl_ca_file_data: ssl_ca_file_data)
    end

    it "writes the ca_bundle file if it does not exist" do
      ssl_ca_file_data = "-----BEGIN CERTIFICATE-----\nMOCK_CERT\n-----END CERTIFICATE-----"
      ssl_ca_file_name = Digest::SHA256.hexdigest(ssl_ca_file_data)
      ca_bundle_filename = File.join(Dir.pwd, "var", "ca_bundles", ssl_ca_file_name + ".crt")
      expect(File).to receive(:exist?).with(ca_bundle_filename).and_return(false)
      expect(File).to receive(:write)
      expect(File).to receive(:rename).with("#{ca_bundle_filename}.tmp", ca_bundle_filename)
      described_class.new(endpoint: endpoint, ssl_ca_file_data: ssl_ca_file_data)
    end

    context "with authentication" do
      let(:username) { "user" }
      let(:password) { "pass" }
      let(:client) { described_class.new(endpoint: endpoint, username: username, password: password) }

      it "creates a client with authentication credentials" do
        expect(client.instance_variable_get(:@username)).to eq(username)
        expect(client.instance_variable_get(:@password)).to eq(password)
      end
    end
  end

  describe "#health" do
    context "when the service is healthy" do
      before do
        stub_request(:get, "#{endpoint}/health")
          .to_return(status: 200)
      end

      it "returns true" do
        expect(client.health).to be true
      end
    end

    context "when the service is unhealthy" do
      before do
        stub_request(:get, "#{endpoint}/health")
          .to_return(status: 500)
      end

      it "raises an error" do
        expect { client.health }.to raise_error(VictoriaMetrics::ClientError)
      end
    end
  end

  describe "#send_request" do
    context "with authentication" do
      let(:username) { "user" }
      let(:password) { "pass" }
      let(:client) { described_class.new(endpoint: endpoint, username: username, password: password) }

      before do
        stub_request(:get, "#{endpoint}/test")
          .with(headers: {"Authorization" => "Basic #{Base64.strict_encode64("#{username}:#{password}")}"})
          .to_return(status: 200)
      end

      it "includes authentication headers" do
        client.send(:send_request, "GET", "/test")
        expect(WebMock).to have_requested(:get, "#{endpoint}/test")
          .with(headers: {"Authorization" => "Basic #{Base64.strict_encode64("#{username}:#{password}")}"})
      end
    end

    context "with different response status codes" do
      it "handles 200 status code" do
        stub_request(:get, "#{endpoint}/test")
          .to_return(status: 200)
        response = client.send(:send_request, "GET", "/test")
        expect(response.status).to eq(200)
      end

      it "handles 204 status code" do
        stub_request(:get, "#{endpoint}/test")
          .to_return(status: 204)
        response = client.send(:send_request, "GET", "/test")
        expect(response.status).to eq(204)
      end

      it "handles 206 status code" do
        stub_request(:get, "#{endpoint}/test")
          .to_return(status: 206)
        response = client.send(:send_request, "GET", "/test")
        expect(response.status).to eq(206)
      end

      it "handles 404 status code" do
        stub_request(:get, "#{endpoint}/test")
          .to_return(status: 404)
        response = client.send(:send_request, "GET", "/test")
        expect(response.status).to eq(404)
      end

      it "raises error for 500 status code" do
        stub_request(:get, "#{endpoint}/test")
          .to_return(status: 500, body: "Internal Server Error")
        expect { client.send(:send_request, "GET", "/test") }.to raise_error(VictoriaMetrics::ClientError, "VictoriaMetrics Client error, method: GET, path: /test, status code: 500")
      end
    end
  end
end
