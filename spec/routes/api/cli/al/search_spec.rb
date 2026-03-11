# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli al search" do
  def insert_audit_log(project_id: @project.id, subject_id: @account.id, object_ids: [], action: "create", ubid_type: "vm", at: Sequel::CURRENT_TIMESTAMP, id: Sequel::DEFAULT)
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

  def search_result(cmd)
    cli(cmd).gsub(/^[-0-9:TZ]+,/, "")
  end

  before do
    @entry_id = insert_audit_log
    @entry_ubid = UBID.from_uuidish(@entry_id).to_s
    @subject_ubid = @account.ubid
  end

  it "shows search of audit log entries" do
    expect(search_result(%w[al search -N])).to eq "vm/create,#{@subject_ubid},\n"
  end

  it "shows headers by default" do
    expect(search_result(%w[al search])).to eq <<~END
      At,Action,Account,Objects
      vm/create,#{@subject_ubid},
    END
  end

  it "-s option filters by subject name/email/UBID" do
    insert_audit_log(subject_id: Account.generate_uuid)
    expect(search_result(%W[al search -N -s #{@subject_ubid}])).to eq "vm/create,#{@subject_ubid},\n"
    expect(search_result(%W[al search -N -s #{@account.email}])).to eq "vm/create,#{@subject_ubid},\n"
    @account.update(name: "Test-User")
    expect(search_result(%W[al search -N -s #{@account.name}])).to eq "vm/create,Test-User,\n"
  end

  it "-a option filters by action" do
    insert_audit_log(action: "destroy", ubid_type: "ps")
    expect(search_result(%W[al search -N -a vm/create])).to eq "vm/create,#{@subject_ubid},\n"
    expect(search_result(%W[al search -N -a vm])).to eq "vm/create,#{@subject_ubid},\n"
    expect(search_result(%W[al search -N -a create])).to eq "vm/create,#{@subject_ubid},\n"
  end

  it "-e option filters by end date" do
    d = Date.today
    insert_audit_log(action: "destroy", at: d << 4)
    expect(search_result(%W[al search -N -e #{d << 3}])).to eq "vm/destroy,#{@subject_ubid},\n"
  end

  it "-o option filters by object UBID" do
    vm = Prog::Vm::Nexus.assemble("k y", @project.id, name: "vm-test").subject
    insert_audit_log(project_id: @project.id, subject_id: @account.id, object_ids: [vm.id, @account.id])
    expect(search_result(%W[al search -N -o #{vm.ubid}])).to eq "vm/create,#{@subject_ubid},#{vm.ubid} #{@account.ubid} \n"
  end

  it "--limit and --pagination-key options work" do
    at = Time.now
    insert_audit_log(action: "destroy", ubid_type: "ps", id: UBID.generate_from_time("a1", at - 10).to_uuid, at:)
    id = insert_audit_log(action: "destroy", ubid_type: "vm", id: UBID.generate_from_time("a1", at).to_uuid, at:)
    args = %W[al search --action=destroy --limit=1 --pagination-key=#{at.strftime("%s.%6N")}/#{UBID.from_uuidish(id)}]

    expect(search_result(%W[al search -N -a destroy --limit=1])).to eq <<~END
      ps/destroy,#{@subject_ubid},
      Continue search: ubi #{args.join(" ")} 
    END

    expect(search_result(args)).to eq <<~END
      At,Action,Account,Objects
      vm/destroy,#{@subject_ubid},
    END
  end
end
