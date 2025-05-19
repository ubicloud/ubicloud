# frozen_string_literal: true

RSpec.describe RunpodClient do
  let(:client) { described_class.new }

  let(:connection) { instance_double(Excon::Connection) }
  let(:api_key) { "test_api_key" }

  before do
    allow(Config).to receive(:runpod_api_key).and_return(api_key)
    allow(Excon).to receive(:new).and_return(connection)
  end

  describe "#create_pod" do
    let(:name) { "test-pod" }
    let(:config) { {foo: "bar"} }

    context "when a pod with the given name exists" do
      let(:pods_response) { [{"id" => "existing-id"}] }
      let(:response) { instance_double(Excon::Response, body: pods_response.to_json) }

      it "returns the existing pod id" do
        expect(connection).to receive(:get).with(path: "v1/pods", query: {name: name}, expects: 200).and_return(response)
        expect(JSON).to receive(:parse).with(response.body).and_return(pods_response)
        expect(client.create_pod(name, config)).to eq("existing-id")
      end
    end

    context "when no pod exists and creation succeeds" do
      let(:pods_response) { [] }
      let(:get_response) { instance_double(Excon::Response, body: pods_response.to_json) }
      let(:post_response) { instance_double(Excon::Response, status: 201, body: {"id" => "new-id"}.to_json) }

      it "creates a new pod and returns its id" do
        expect(connection).to receive(:get).and_return(get_response)
        expect(JSON).to receive(:parse).with(get_response.body).and_return(pods_response)
        expect(connection).to receive(:post).with(path: "v1/pods", body: config.to_json).and_return(post_response)
        expect(post_response).to receive(:status).and_return(201)
        expect(JSON).to receive(:parse).with(post_response.body).and_return({"id" => "new-id"})
        expect(client.create_pod(name, config)).to eq("new-id")
      end
    end

    context "when pod creation fails" do
      let(:pods_response) { [] }
      let(:get_response) { instance_double(Excon::Response, body: pods_response.to_json) }
      let(:post_response) { instance_double(Excon::Response, status: 400, body: "error") }

      it "raises an error" do
        expect(connection).to receive(:get).and_return(get_response)
        expect(JSON).to receive(:parse).with(get_response.body).and_return(pods_response)
        expect(connection).to receive(:post).and_return(post_response)
        expect(post_response).to receive(:status).and_return(400)
        expect { client.create_pod("name", {}) }.to raise_error(RuntimeError, /Failed to create pod/)
      end
    end
  end

  describe "#get_pod" do
    let(:pod_id) { "abc123" }
    let(:response) { instance_double(Excon::Response, body: {"id" => pod_id, "status" => "running"}.to_json) }

    it "returns the pod details" do
      expect(connection).to receive(:get).with(path: "v1/pods/#{pod_id}", expects: 200).and_return(response)
      expect(client.get_pod(pod_id)).to eq({"id" => pod_id, "status" => "running"})
    end
  end

  describe "#delete_pod" do
    let(:pod_id) { "abc123" }

    it "calls delete on the connection" do
      expect(connection).to receive(:delete).with(path: "v1/pods/#{pod_id}", expects: 200)
      client.delete_pod(pod_id)
    end
  end
end
