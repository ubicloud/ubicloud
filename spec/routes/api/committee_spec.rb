# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "committee infrastructure" do
  let(:user) { create_account }
  let(:project) { project_with_default_policy(user) }

  before do
    login_api
  end

  it "serializes unexpected nested errors that cannot be converted" do
    ex = Class.new(Committee::BadRequest) do
      def self.name
        "CommitteeTestNestedException"
      end

      def original_error
        Exception.new("unaddressed error value")
      end
    end.new("testing conversion of unenumerated nested exceptions")

    allow_any_instance_of(Committee::SchemaValidator::OpenAPI3).to receive(:request_validate) do
      raise ex
    end

    expect {
      project
      post "/project/#{UBID.generate(UBID::TYPE_PROJECT)}/location/#{TEST_LOCATION}/vm/test-vm"
    }.to raise_error ex
  end

  it "raises in tests for paths that cannot be found in the schema" do
    project
    expect { post "/not-a-prefix/" }.to raise_error(RuntimeError, "request not found in openapi schema: POST /not-a-prefix/")
  end

  it "returns 404 for paths that cannot be found in the schema" do
    ENV["IGNORE_INVALID_API_PATHS"] = "1"
    project
    post "/not-a-prefix/"
    expect(JSON.parse(last_response.body).dig("error", "message")).to eq("Sorry, we couldn’t find the resource you’re looking for.")
  ensure
    ENV.delete("IGNORE_INVALID_API_PATHS")
  end

  it "fails when the request has unparsable json" do
    expect {
      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/vm/test-vm", "this is not json"
    }.to raise_error Committee::InvalidRequest, "Request body wasn't valid JSON."
  end

  it "fails when response has invalid structure" do
    expect(Serializers::Vm).to receive(:serialize_internal).and_return({totally_not_correct: true})
    expect {
      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/vm/test-vm", {
        public_key: "ssh key",
        unix_user: "ubi",
        size: "standard-2",
        boot_image: "ubuntu-jammy",
        storage_size: "40"
      }.to_json
    }.to raise_error Committee::InvalidResponse, %r{#/components/schemas/Vm missing required parameters: .*}
  end

  it "fails when request has invalid parameter" do
    expect {
      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/vm/INVALID", {
        public_key: "ssh key",
        unix_user: "ubi",
        size: "standard-2",
        boot_image: "ubuntu-jammy",
        storage_size: "40"
      }.to_json
    }.to raise_error Committee::InvalidRequest, '#/components/schemas/Reference pattern ^[a-z0-9](?:[a-z0-9\-]{0,61}[a-z0-9])?$ does not match value: "INVALID"'
  end

  it "fails when request is missing required keys" do
    expect {
      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/vm/test-vm", {}.to_json
    }.to raise_error Committee::InvalidRequest, /missing required parameters: public_key/
  end

  it "fails when request has extra unexpected keys" do
    expect {
      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/vm/test-vm", {missing_stuff: true}.to_json
    }.to raise_error Committee::InvalidRequest, /schema does not define properties: missing_stuff/
  end

  it "reports if response body is not valid JSON" do
    allow_any_instance_of(Committee::SchemaValidator::OpenAPI3).to receive(:response_validate) do
      raise JSON::ParserError.new("injected parser error")
    end

    expect {
      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/vm/test-vm", {
        public_key: "ssh key",
        unix_user: "ubi",
        size: "standard-2",
        boot_image: "ubuntu-jammy",
        storage_size: "40"
      }.to_json
    }.to raise_error Committee::InvalidResponse, "Response body wasn't valid JSON."
  end
end
