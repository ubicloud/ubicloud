# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "auth" do
  it "no jwt token" do
    get "/runtime"

    expect(last_response.status).to eq(400)
    expect(JSON.parse(last_response.body)["error"]["type"]).to eq("InvalidRequest")
  end

  it "wrong jwt token" do
    header "Authorization", "Bearer wrongjwt"
    get "/runtime"

    expect(last_response.status).to eq(400)
    expect(JSON.parse(last_response.body)["error"]["type"]).to eq("InvalidRequest")
  end

  it "valid jwt token but no active vm" do
    vm = Vm.new_with_id
    header "Authorization", "Bearer #{vm.runtime_token}"
    get "/runtime"

    expect(last_response.status).to eq(400)
    expect(JSON.parse(last_response.body)["error"]["type"]).to eq("InvalidRequest")
  end

  it "valid jwt token with an active vm" do
    login_runtime(create_vm)
    get "/runtime"

    expect(last_response.status).to eq(404)
  end
end
