# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "managed identity authentication" do
  let(:project) { Project.create(name: "test") }
  let(:vm) { create_vm(project_id: project.id, name: "mi-vm") }
  let(:token) { ApiKey.create_managed_identity_token(vm) }

  def authenticate
    header "Authorization", "Bearer pat-#{token.ubid}-#{token.key}"
  end

  def grant(action)
    AccessControlEntry.create(project_id: project.id, subject_id: vm.id, action_id: ActionType::NAME_MAP[action])
  end

  it "rejects an invalid managed identity token" do
    header "Authorization", "Bearer pat-#{token.ubid}-wrongkey"
    get "/project/#{project.ubid}"
    expect(last_response).to have_api_error(401, "invalid personal access token provided in Authorization header")
  end

  it "authenticates the VM and authorizes it through access control entries" do
    authenticate

    # Authenticated, but no permissions granted yet.
    get "/project/#{project.ubid}"
    expect(last_response.status).to eq(403)

    grant("Project:view")
    get "/project/#{project.ubid}"
    expect(last_response.status).to eq(200)
    expect(JSON.parse(last_response.body)["id"]).to eq(project.ubid)
  end

  it "authorizes through a subject tag the VM is a member of" do
    tag = SubjectTag.create(project_id: project.id, name: "Identities")
    tag.add_subject(vm.id)
    AccessControlEntry.create(project_id: project.id, subject_id: tag.id, action_id: ActionType::NAME_MAP["Project:view"])

    authenticate
    get "/project/#{project.ubid}"
    expect(last_response.status).to eq(200)
  end

  it "treats a project that is not the identity's own as not found" do
    other_project = Project.create(name: "other")
    grant("Project:view")

    authenticate
    get "/project/#{other_project.ubid}"
    expect(last_response.status).to eq(404)
  end

  it "denies access to routes that require an account" do
    authenticate
    get "/project"
    expect(last_response.status).to eq(403)
  end

  it "resolves the project for the ubi CLI (/cli) using the managed identity" do
    authenticate
    header "Accept", "text/plain"
    post "/cli", {"argv" => ["vm", "list"]}.to_json
    expect(last_response.status).to eq(200)
  end

  it "records the VM as the audit subject when it performs a write" do
    AccessControlEntry.create(project_id: project.id, subject_id: vm.id, action_id: ActionType::NAME_MAP["Firewall:create"])
    authenticate
    post "/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/mi-firewall", {description: "x"}.to_json
    expect(last_response.status).to eq(200)
    expect(DB[:audit_log].where(project_id: project.id, subject_id: vm.id).count).to eq(1)
  end
end
