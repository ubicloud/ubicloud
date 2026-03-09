# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli al list" do
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

  before do
    @entry_id = insert_audit_log(project_id: @project.id, subject_id: @account.id)
    @entry_ubid = UBID.from_uuidish(@entry_id).to_s
    @subject_ubid = @account.ubid
  end

  it "shows list of audit log entries" do
    result = cli(%w[al list -N])
    expect(result).to include(@entry_ubid)
    expect(result).to include(@subject_ubid)
    expect(result).to include("create")
    expect(result).to include("vm")
  end

  it "shows headers by default" do
    result = cli(%w[al list])
    expect(result).to include("id")
    expect(result).to include("at")
    expect(result).to include("action")
    expect(result).to include("subject-id")
    expect(result).to include("ubid-type")
    expect(result).to include("object-ids")
  end

  it "-N hides headers" do
    result = cli(%w[al list -N])
    expect(result).not_to start_with("id")
  end

  it "-f id option includes only id field" do
    result = cli(%w[al list -Nfid])
    expect(result).to eq "#{@entry_ubid}\n"
  end

  it "-f action option includes only action field" do
    result = cli(%w[al list -Nfaction])
    expect(result).to eq "create\n"
  end

  it "-s option filters by subject UBID" do
    other_id = insert_audit_log(project_id: @project.id, subject_id: Account.generate_uuid)
    result = cli(%w[al list -N] + ["-s", @subject_ubid])
    expect(result).to include(@entry_ubid)
    expect(result).not_to include(UBID.from_uuidish(other_id).to_s)
  end

  it "-o option filters by object UBID" do
    vm_id = Prog::Vm::Nexus.assemble("k y", @project.id, name: "vm-test").subject.id
    vm_ubid = UBID.from_uuidish(vm_id).to_s
    insert_audit_log(project_id: @project.id, subject_id: @account.id, object_ids: [vm_id])

    result = cli(%w[al list -N] + ["-o", vm_ubid])
    expect(result).not_to include(@entry_ubid)
  end

  it "shows error for empty fields" do
    expect(cli(%w[al list -Nf] + [""], status: 400)).to start_with "! No fields given in al list -f option\n"
  end

  it "shows error for duplicate fields" do
    expect(cli(%w[al list -Nfid,id], status: 400)).to start_with "! Duplicate field(s) in al list -f option\n"
  end

  it "shows error for invalid fields" do
    expect(cli(%w[al list -Nffoo], status: 400)).to start_with "! Invalid field(s) given in al list -f option: foo\n"
  end
end
