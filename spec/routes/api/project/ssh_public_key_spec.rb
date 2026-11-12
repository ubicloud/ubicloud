# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "ssh public key" do
  let(:user) { create_account }

  let(:project) { project_with_default_policy(user) }

  let(:ssh_public_key) { SshPublicKey.create(project_id: project.id, name: "spk", public_key: "a a") }

  before do
    login_api
  end

  it "updates the name and public key together" do
    post "/project/#{project.ubid}/ssh-public-key/#{ssh_public_key.ubid}", {name: "spk2", public_key: "b b"}.to_json

    expect(last_response.status).to eq(200)
    expect(ssh_public_key.reload.name).to eq "spk2"
    expect(ssh_public_key.public_key).to eq "b b"
  end

  it "fails to update with an empty body" do
    expect {
      post "/project/#{project.ubid}/ssh-public-key/#{ssh_public_key.ubid}", {}.to_json
    }.to raise_error(Committee::InvalidRequest, /less than minProperties/)
  end

  it "fails to update with an unrecognized property, naming it" do
    expect {
      post "/project/#{project.ubid}/ssh-public-key/#{ssh_public_key.ubid}", {name: "spk2", x: 1}.to_json
    }.to raise_error(Committee::InvalidRequest, /does not define properties: x/)
  end
end
