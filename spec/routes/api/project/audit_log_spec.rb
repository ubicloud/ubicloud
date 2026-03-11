# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "audit log" do
  let(:user) { create_account }

  let(:project) { project_with_default_policy(user) }

  def insert_audit_log(project_id:, subject_id:, object_ids: [], action: "create", ubid_type: "vm", at: Sequel::CURRENT_TIMESTAMP, id: Sequel::DEFAULT)
    DB[:audit_log].returning(:id).insert(
      id:,
      at:,
      ubid_type:,
      action:,
      project_id:,
      subject_id:,
      object_ids: Sequel.pg_array(object_ids, :uuid)
    ).first[:id]
  end

  def audit_log_body(path, delete_at: true)
    get path
    expect(last_response.status).to eq(200)
    body = JSON.parse(last_response.body)
    body["items"].each { it.delete("at") } if delete_at
    body
  end

  before do
    login_api
  end

  it "returns audit log entries" do
    user.update(name: "Test-Name")
    at = Time.now
    insert_audit_log(project_id: project.id, subject_id: user.id, at:)

    expect(audit_log_body("/project/#{project.ubid}/audit-log", delete_at: false))
      .to eq({"items" => [{"action" => "vm/create", "at" => at.getutc.iso8601, "object_ids" => [], "subject_id" => user.ubid, "subject_name" => "Test-Name"}]})
  end

  it "filters by subject UBID" do
    other = Account.generate_ubid
    insert_audit_log(project_id: project.id, subject_id: user.id)
    insert_audit_log(project_id: project.id, subject_id: other.to_uuid)

    expect(audit_log_body("/project/#{project.ubid}/audit-log?subject=#{user.ubid}"))
      .to eq({"items" => [{"action" => "vm/create", "object_ids" => [], "subject_id" => user.ubid}]})

    expect(audit_log_body("/project/#{project.ubid}/audit-log?subject=#{other}"))
      .to eq({"items" => [{"action" => "vm/create", "object_ids" => [], "subject_id" => other.to_s}]})
  end

  it "filters by object UBID" do
    vm = Prog::Vm::Nexus.assemble("k y", project.id, name: "vm-test").subject
    insert_audit_log(project_id: project.id, subject_id: user.id, object_ids: [vm.id])
    insert_audit_log(project_id: project.id, subject_id: user.id)

    expect(audit_log_body("/project/#{project.ubid}/audit-log?object=#{vm.ubid}"))
      .to eq({"items" => [{"action" => "vm/create", "object_ids" => [vm.ubid], "subject_id" => user.ubid}]})
  end

  it "filters by action" do
    insert_audit_log(project_id: project.id, subject_id: user.id)
    insert_audit_log(action: "destroy", project_id: project.id, subject_id: user.id)

    expect(audit_log_body("/project/#{project.ubid}/audit-log?action=destroy"))
      .to eq({"items" => [{"action" => "vm/destroy", "object_ids" => [], "subject_id" => user.ubid}]})
  end

  it "filters by end date" do
    d = Date.today
    insert_audit_log(project_id: project.id, subject_id: user.id, at: d << 4)
    insert_audit_log(action: "destroy", project_id: project.id, subject_id: user.id)

    expect(audit_log_body("/project/#{project.ubid}/audit-log?end=#{d << 3}"))
      .to eq({"items" => [{"action" => "vm/create", "object_ids" => [], "subject_id" => user.ubid}]})
  end

  it "supports limits and pagination keys" do
    vm = Prog::Vm::Nexus.assemble("k y", project.id, name: "vm-test").subject
    at = Time.now - 1
    insert_audit_log(project_id: project.id, subject_id: user.id, object_ids: [vm.id], at:, id: UBID.generate_from_time("a1", Time.now - 10).to_uuid)
    id = insert_audit_log(action: "destroy", project_id: project.id, subject_id: user.id, at:, id: UBID.generate_from_time("a1", Time.now).to_uuid)
    pagination_key = "#{at.strftime("%s.%6N")}/#{UBID.from_uuidish(id)}"

    expect(audit_log_body("/project/#{project.ubid}/audit-log?limit=1"))
      .to eq({
        "items" => [{"action" => "vm/create", "object_ids" => [vm.ubid], "subject_id" => user.ubid}],
        "pagination_key" => pagination_key
      })
    expect(audit_log_body("/project/#{project.ubid}/audit-log?limit=1&pagination_key=#{pagination_key}"))
      .to eq({"items" => [{"action" => "vm/destroy", "object_ids" => [], "subject_id" => user.ubid}]})
  end

  it "returns empty items for invalid subject UBID" do
    insert_audit_log(project_id: project.id, subject_id: user.id)

    expect(audit_log_body("/project/#{project.ubid}/audit-log?subject=not-a-ubid")).to eq({"items" => []})
  end

  it "returns empty items for invalid object UBID" do
    insert_audit_log(project_id: project.id, subject_id: user.id)

    expect(audit_log_body("/project/#{project.ubid}/audit-log?object=not-a-ubid")).to eq({"items" => []})
  end

  it "does not return entries from other projects" do
    other_project = project_with_default_policy(user)
    insert_audit_log(project_id: other_project.id, subject_id: user.id)

    expect(audit_log_body("/project/#{project.ubid}/audit-log")).to eq({"items" => []})
  end

  it "returns 403 when user lacks permission" do
    project
    AccessControlEntry.dataset.destroy
    AccessControlEntry.create(project_id: project.id, subject_id: @pat.id, action_id: ActionType::NAME_MAP["Project:view"])

    get "/project/#{project.ubid}/audit-log"
    expect(last_response).to have_api_error(403, "Sorry, you don't have permission to continue with this request.")
  end
end
