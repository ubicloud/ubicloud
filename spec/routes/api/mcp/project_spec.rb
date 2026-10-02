# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "mcp project tools" do
  describe "get_object_info" do
    let(:vm) { create_vm(project_id: @project.id) }
    let(:info) { {"type" => "vm", "location" => "eu-central-h1", "name" => "test-vm"} }

    it "resolves an id to its type, location and name" do
      result = mcp_tool("get_object_info", id: vm.ubid)
      expect(result).to eq({
        "content" => [{"type" => "text", "text" => info.to_json}],
        "isError" => false,
        "structuredContent" => info,
      })
    end

    it "works with a token restricted to Vm:view" do
      restrict_pat_to("Vm:view")
      expect(mcp_tool_data("get_object_info", id: vm.ubid)).to eq info
    end

    it "returns ResourceNotFound when the token lacks the view permission" do
      restrict_pat_to("Project:view")
      expect(mcp_tool_error("get_object_info", id: vm.ubid)).to start_with "ResourceNotFound: "
    end

    it "returns ResourceNotFound for an unknown id" do
      expect(mcp_tool_error("get_object_info", id: "vm345678901234567890123456")).to start_with "ResourceNotFound: "
    end

    it "rejects a malformed id or the id of an unsupported type before calling the API" do
      expect(described_class).not_to receive(:call)

      ["foo", "#{vm.ubid}\nx", @account.ubid].each do |id|
        expect(mcp_tool_error("get_object_info", id:)).to eq "InvalidRequest: id must be a resource id such as vm..."
      end
    end
  end

  describe "list_audit_log" do
    let(:two_days_ago) { Time.now.floor - 2 * 86400 }

    def insert_audit_log(at:, ubid_type: "vm", action: "create", subject_id: @account.id, object_ids: [])
      DB[:audit_log].returning(:id).insert(
        id: Sequel::DEFAULT,
        at:,
        ubid_type:,
        action:,
        project_id: @project.id,
        subject_id:,
        object_ids: Sequel.pg_array(object_ids, :uuid),
      ).first[:id]
    end

    def cursor_for(at, id)
      "#{at.strftime("%s.%6N")}/#{UBID.to_ubid(id)}"
    end

    def audit_log_items(key, **)
      mcp_tool_data("list_audit_log", **)["items"].map { it[key] }
    end

    it "lists entries newest first with the subject name" do
      @account.update(name: "Test-Name")
      vm = create_vm(project_id: @project.id)
      insert_audit_log(at: two_days_ago - 60, object_ids: [vm.id])
      insert_audit_log(at: two_days_ago - 30, ubid_type: "pg", action: "restart")

      expect(mcp_tool_data("list_audit_log")).to eq({
        "items" => [
          {"at" => (two_days_ago - 30).getutc.iso8601, "action" => "pg/restart", "subject_id" => @account.ubid, "object_ids" => [], "subject_name" => "Test-Name"},
          {"at" => (two_days_ago - 60).getutc.iso8601, "action" => "vm/create", "subject_id" => @account.ubid, "object_ids" => [vm.ubid], "subject_name" => "Test-Name"},
        ],
        "next_cursor" => nil,
      })
    end

    it "works with a token restricted to Project:auditlog" do
      insert_audit_log(at: two_days_ago)
      restrict_pat_to("Project:auditlog")
      expect(audit_log_items("action")).to eq ["vm/create"]
    end

    it "returns Forbidden when the token lacks Project:auditlog" do
      insert_audit_log(at: two_days_ago)
      restrict_pat_to("Project:view")
      expect(mcp_tool_error("list_audit_log")).to eq "Forbidden: Sorry, you don't have permission to continue with this request."
    end

    it "filters by action, bare type or bare action" do
      insert_audit_log(at: two_days_ago - 60)
      insert_audit_log(at: two_days_ago - 30, ubid_type: "pg", action: "restart")
      insert_audit_log(at: two_days_ago, ubid_type: "pg", action: "destroy")

      expect(audit_log_items("action", action: "pg/restart")).to eq ["pg/restart"]
      expect(audit_log_items("action", action: "pg")).to eq ["pg/destroy", "pg/restart"]
      expect(audit_log_items("action", action: "restart")).to eq ["pg/restart"]
    end

    it "filters by subject id, name or email and returns no entries for an unknown subject" do
      @account.update(name: "Test-Name")
      insert_audit_log(at: two_days_ago - 60)
      insert_audit_log(at: two_days_ago, subject_id: Account.generate_uuid, action: "destroy")

      [@account.ubid, "Test-Name", @account.email].each do |subject|
        expect(audit_log_items("action", subject:)).to eq ["vm/create"]
      end
      expect(audit_log_items("action", subject: "nobody")).to eq []
    end

    it "filters by object id and returns no entries for a malformed object id" do
      vm = create_vm(project_id: @project.id)
      insert_audit_log(at: two_days_ago - 60, object_ids: [vm.id])
      insert_audit_log(at: two_days_ago, action: "destroy")

      expect(audit_log_items("object_ids", object: vm.ubid)).to eq [[vm.ubid]]
      expect(audit_log_items("object_ids", object: "foo")).to eq []
    end

    it "searches and pages the 3 months ending on end, which can be 3 months before or after today" do
      insert_audit_log(at: two_days_ago - 160 * 86400, action: "rename")
      insert_audit_log(at: two_days_ago - 150 * 86400, action: "update")
      insert_audit_log(at: two_days_ago - 120 * 86400)
      insert_audit_log(at: two_days_ago, action: "destroy")
      insert_audit_log(at: two_days_ago + 40 * 86400, action: "restart")
      earliest_end = (Date.today << 3).to_s

      expect(audit_log_items("action", end: earliest_end)).to eq ["vm/create", "vm/update", "vm/rename"]
      cursor = mcp_tool_data("list_audit_log", end: earliest_end, limit: 1)["next_cursor"]
      expect(audit_log_items("action", end: earliest_end, cursor:)).to eq ["vm/update", "vm/rename"]
      expect(audit_log_items("action", end: (Date.today >> 3).to_s, action: "restart")).to eq ["vm/restart"]
    end

    it "rejects an end that is not a YYYY-MM-DD date within 3 months of today before calling the API" do
      today = Date.today
      expect(described_class).not_to receive(:call)

      ["yesterday", today.strftime("%Y%m%d"), "#{today}\n", "0#{today}", "2026-02-31", ((today << 3) - 1).to_s, ((today >> 3) + 1).to_s].each do |end_date|
        expect(mcp_tool_error("list_audit_log", end: end_date)).to eq "InvalidRequest: end must be a YYYY-MM-DD date from #{today << 3} to #{today >> 3}"
      end
    end

    it "rejects a cursor that is malformed or that the API would ignore before calling the API" do
      cursor = cursor_for(two_days_ago, insert_audit_log(at: two_days_ago))
      id = cursor.split("/").last
      garbled_id = id[..-2] + UBID.from_base32(UBID.to_base32(id[-1]) ^ 1)
      expect(described_class).not_to receive(:call)

      [
        cursor[..-2], "#{cursor}\n", "junk", "vm345678901234567890123456", "#{two_days_ago.to_i}/#{id}",
        "#{two_days_ago.to_i}.1/#{id}", "#{two_days_ago.to_i},000000/#{id}", "#{two_days_ago.to_i}.000000x#{id}",
        "#{two_days_ago.to_i}.000000/#{@project.ubid}", "#{two_days_ago.to_i}.000000/a1#{id[2..].upcase}",
        "#{two_days_ago.to_i}.000000/#{garbled_id}", "#{two_days_ago.to_i}0.000000/#{id}", "99999999999999999999.000000/#{id}",
        "1746082800.999999/#{id}",
      ].each do |bad|
        expect(mcp_tool_error("list_audit_log", cursor: bad)).to eq "InvalidRequest: cursor must be the next_cursor of a previous result"
      end
    end

    it "accepts a cursor with the earliest time the API uses" do
      id = UBID.to_ubid(insert_audit_log(at: two_days_ago))
      expect(audit_log_items("action", cursor: "1746082801.000000/#{id}")).to eq []
    end

    it "sends an integral float limit as an integer" do
      insert_audit_log(at: two_days_ago)
      expect(described_class).to receive(:call).and_wrap_original do |original, env|
        expect(env["QUERY_STRING"]).to eq "limit=1"
        original.call(env)
      end

      expect(audit_log_items("action", limit: 1.0)).to eq ["vm/create"]
    end

    it "pages with the cursor" do
      insert_audit_log(at: two_days_ago)
      older_id = insert_audit_log(at: two_days_ago - 60, action: "destroy")

      page = mcp_tool_data("list_audit_log", limit: 1)
      expect(page["items"].map { it["action"] }).to eq ["vm/create"]
      expect(page["next_cursor"]).to eq cursor_for(two_days_ago - 60, older_id)

      page = mcp_tool_data("list_audit_log", limit: 1, cursor: page["next_cursor"])
      expect(page["items"].map { it["action"] }).to eq ["vm/destroy"]
      expect(page["next_cursor"]).to be_nil
    end

    it "returns 50 entries per page by default" do
      ids = Array.new(51) { insert_audit_log(at: two_days_ago - it) }

      page = mcp_tool_data("list_audit_log")
      expect(page["items"].size).to eq 50
      expect(page["next_cursor"]).to eq cursor_for(two_days_ago - 50, ids.last)
    end
  end
end
