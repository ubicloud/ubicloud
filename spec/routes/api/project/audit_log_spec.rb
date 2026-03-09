# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "audit log" do
  let(:user) { create_account }

  let(:project) { project_with_default_policy(user) }

  def insert_audit_log(project_id:, subject_id:, object_ids: [], action: "create", ubid_type: "vm", at: Time.now)
    DB[:audit_log].returning(:id).insert(
      at:,
      ubid_type:,
      action:,
      project_id:,
      subject_id:,
      object_ids: Sequel.pg_array(object_ids, :uuid)
    ).first[:id]
  end

  describe "unauthenticated" do
    it "not list" do
      get "/project/#{project.ubid}/audit-log"

      expect(last_response).to have_api_error(401, "must include personal access token in Authorization header")
    end
  end

  describe "authenticated" do
    before do
      login_api
    end

    it "returns audit log entries" do
      id = insert_audit_log(project_id: project.id, subject_id: user.id)

      get "/project/#{project.ubid}/audit-log"

      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["items"].length).to eq(1)
      expect(body["items"].first["id"]).to eq(UBID.from_uuidish(id).to_s)
    end

    it "filters by subject UBID" do
      other_id = Account.generate_uuid
      insert_audit_log(project_id: project.id, subject_id: user.id)
      insert_audit_log(project_id: project.id, subject_id: other_id)

      get "/project/#{project.ubid}/audit-log?subject=#{user.ubid}"

      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["items"].length).to eq(1)
      expect(body["items"].first["subject_id"]).to eq(user.ubid)
    end

    it "filters by object UBID" do
      vm_id = Prog::Vm::Nexus.assemble("k y", project.id, name: "vm-test").subject.id
      vm_ubid = UBID.from_uuidish(vm_id).to_s
      insert_audit_log(project_id: project.id, subject_id: user.id, object_ids: [vm_id])
      insert_audit_log(project_id: project.id, subject_id: user.id)

      get "/project/#{project.ubid}/audit-log?object=#{vm_ubid}"

      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["items"].length).to eq(1)
      expect(body["items"].first["object_ids"]).to include(vm_ubid)
    end

    it "returns empty items for invalid subject UBID" do
      insert_audit_log(project_id: project.id, subject_id: user.id)

      get "/project/#{project.ubid}/audit-log?subject=not-a-ubid"

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["items"]).to be_empty
    end

    it "returns empty items for invalid object UBID" do
      insert_audit_log(project_id: project.id, subject_id: user.id)

      get "/project/#{project.ubid}/audit-log?object=not-a-ubid"

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["items"]).to be_empty
    end

    it "does not return entries from other projects" do
      other_project = project_with_default_policy(user)
      insert_audit_log(project_id: other_project.id, subject_id: user.id)

      get "/project/#{project.ubid}/audit-log"

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["items"]).to be_empty
    end

    it "returns 403 when user lacks permission" do
      project
      AccessControlEntry.dataset.destroy
      AccessControlEntry.create(project_id: project.id, subject_id: @pat.id, action_id: ActionType::NAME_MAP["Project:view"])

      get "/project/#{project.ubid}/audit-log"

      expect(last_response).to have_api_error(403, "Sorry, you don't have permission to continue with this request.")
    end
  end
end
