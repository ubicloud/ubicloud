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
      expect { client.create_stream(stream_name: "mystream") }.not_to raise_error
    end

    it "does not raise an error in case the stream already exists" do
      stub_request(:put, "#{endpoint}/api/v1/logstream/mystream").to_return(status: 400, body: "Logstream mystream already exists")
      expect { client.create_stream(stream_name: "mystream") }.not_to raise_error
    end

    it "raises Client::Error on non-success status" do
      stub_request(:put, "#{endpoint}/api/v1/logstream/mystream").to_return(status: 500)
      expect { client.create_stream(stream_name: "mystream") }.to raise_error(Parseable::Client::Error)
    end
  end

  describe "#delete_stream" do
    it "sends a DELETE request for the stream" do
      stub_request(:delete, "#{endpoint}/api/v1/logstream/mystream").to_return(status: 200)
      expect { client.delete_stream(stream_name: "mystream") }.not_to raise_error
    end

    it "does not raise an error if the stream does not exist" do
      stub_request(:delete, "#{endpoint}/api/v1/logstream/mystream").to_return(status: 404)
      expect { client.delete_stream(stream_name: "mystream") }.not_to raise_error
    end

    it "raises an error on non-success status" do
      stub_request(:delete, "#{endpoint}/api/v1/logstream/mystream").to_return(status: 500)
      expect { client.delete_stream(stream_name: "mystream") }.to raise_error(Parseable::Client::Error)
    end
  end

  describe "#create_role" do
    it "sends a PUT request for the role" do
      stub_request(:put, "#{endpoint}/api/v1/role/myrole").to_return(status: 200)
      expect { client.create_role(role_name: "myrole", privileges: [{privilege: "ingester", resource: {type: "Stream", name: "mystream"}}]) }.not_to raise_error
    end

    it "raises Client::Error on non-success status" do
      stub_request(:put, "#{endpoint}/api/v1/role/myrole").to_return(status: 500)
      expect { client.create_role(role_name: "myrole", privileges: []) }.to raise_error Parseable::Client::Error
    end
  end

  describe "#delete_role" do
    it "sends a DELETE request for the role" do
      stub_request(:delete, "#{endpoint}/api/v1/role/myrole").to_return(status: 200)
      expect { client.delete_role(role_name: "myrole") }.not_to raise_error
    end

    it "does not raise an error if the role does not exist" do
      stub_request(:delete, "#{endpoint}/api/v1/role/myrole").to_return(status: 404)
      expect { client.delete_role(role_name: "myrole") }.not_to raise_error
    end

    it "raises Client::Error on non-success status" do
      stub_request(:delete, "#{endpoint}/api/v1/role/myrole").to_return(status: 400)
      expect { client.delete_role(role_name: "myrole") }.to raise_error Parseable::Client::Error
    end
  end

  describe "#create_user" do
    it "sends a POST request and returns the generated password" do
      stub_request(:post, "#{endpoint}/api/v1/user/myuser")
        .with(body: '["myrole"]', headers: {"Content-Type" => "application/json"})
        .to_return(status: 200, body: "generated-pw")
      expect(client.create_user(user_id: "myuser", roles: ["myrole"])).to eq("generated-pw")
    end

    it "sends a POST request with no roles when called with empty array" do
      stub_request(:post, "#{endpoint}/api/v1/user/myuser")
        .with(body: "[]")
        .to_return(status: 200, body: "pw")
      expect(client.create_user(user_id: "myuser")).to eq("pw")
    end

    it "retries creating the user if the user already exists" do
      stub_request(:post, "#{endpoint}/api/v1/user/myuser").to_return(status: 400, body: "User myuser already exists")
      stub_request(:delete, "#{endpoint}/api/v1/user/myuser").to_return(status: 200)
      stub_request(:post, "#{endpoint}/api/v1/user/myuser").to_return(status: 200, body: "pw")
      expect(client.create_user(user_id: "myuser")).to eq("pw")
    end

    it "raises Client::Error with response_body if retries are exhausted" do
      stub_request(:post, "#{endpoint}/api/v1/user/myuser").to_return(status: 400, body: "User myuser already exists")
      stub_request(:delete, "#{endpoint}/api/v1/user/myuser").to_return(status: 200)
      expect { client.create_user(user_id: "myuser") }.to raise_error(Parseable::Client::Error)
    end

    it "raises Client::Error with response_body on non-success status" do
      stub_request(:post, "#{endpoint}/api/v1/user/myuser").to_return(status: 400)
      expect { client.create_user(user_id: "myuser") }.to raise_error(Parseable::Client::Error)
    end
  end

  describe "#delete_user" do
    it "sends a DELETE request for the user" do
      stub_request(:delete, "#{endpoint}/api/v1/user/myuser").to_return(status: 200)
      expect { client.delete_user(user_id: "myuser") }.not_to raise_error
    end

    it "does not raise an error if the user does not exist" do
      stub_request(:delete, "#{endpoint}/api/v1/user/myuser").to_return(status: 404)
      expect { client.delete_user(user_id: "myuser") }.not_to raise_error
    end

    it "raises an error if the request fails" do
      stub_request(:delete, "#{endpoint}/api/v1/user/myuser").to_return(status: 400)
      expect { client.delete_user(user_id: "myuser") }.to raise_error(Parseable::Client::Error)
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
