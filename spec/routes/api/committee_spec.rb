# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "committee infrastructure" do
  let(:user) { create_account }
  let(:project) { user.create_project_with_default_policy("project-1") }

  before do
    login_api(user.email)
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

    post "/project/#{UBID.generate(UBID::TYPE_PROJECT)}/location/#{TEST_LOCATION}/vm/test-vm"

    expect(JSON.parse(last_response.body).dig("error", "message")).to eq("testing conversion of unenumerated nested exceptions")
  end

  it "rejects paths that cannot be found in the schema" do
    post "/not-a-prefix/"
    expect(JSON.parse(last_response.body).dig("error", "message")).to eq("That request method and path combination isn't defined.")
  end

  it "fails when response has invalid structure" do
    expect(Serializers::Vm).to receive(:serialize_internal).and_return({totally_not_correct: true})
    post "/project/#{project.ubid}/location/#{TEST_LOCATION}/vm/test-vm", {
      public_key: "ssh key",
      unix_user: "ubi",
      size: "standard-2",
      boot_image: "ubuntu-jammy",
      storage_size: "40"
    }.to_json
    expect(JSON.parse(last_response.body).dig("error", "message")).to match(%r{#/components/schemas/Vm missing required parameters: .*})
  end

  it "reports if response body is not valid JSON" do
    allow_any_instance_of(Committee::SchemaValidator::OpenAPI3).to receive(:response_validate) do
      raise JSON::ParserError.new("injected parser error")
    end

    post "/project/#{project.ubid}/location/#{TEST_LOCATION}/vm/test-vm", {
      public_key: "ssh key",
      unix_user: "ubi",
      size: "standard-2",
      boot_image: "ubuntu-jammy",
      storage_size: "40"
    }.to_json

    expect(JSON.parse(last_response.body).dig("error", "message")).to eq("Response body wasn't valid JSON.")
  end
end
