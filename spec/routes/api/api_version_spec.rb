# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "api version" do
  let(:user) { create_account }

  let(:project) { project_with_default_policy(user) }

  let(:firewall) { Firewall.create(name: "fw", location_id: Location::HETZNER_FSN1_ID, project_id: project.id) }

  let(:rule_path) { "/project/#{project.ubid}/location/#{TEST_LOCATION}/firewall/#{firewall.name}/firewall-rule" }

  let(:v2) { "application/vnd.ubicloud+json; version=2" }

  before do
    login_api
    allow(Clog).to receive(:emit).and_call_original
    allow(Config).to receive(:postgres_service_project_id).and_return(Project.create(name: "default").id)
  end

  def list_vms(accept)
    header "Accept", accept
    get "/project/#{project.ubid}/location/#{TEST_LOCATION}/vm"
  end

  def add_rule(accept, cidr: "10.0.0.0/8", **body)
    header "Accept", accept
    post rule_path, {cidr:, **body}.to_json
  end

  def error = JSON.parse(last_response.body)["error"]

  describe "the Accept header" do
    it "gives version 1 without the vendor media type, or with version=1" do
      [nil, "", "application/json", "text/plain", "*/*", "application/vnd.ubicloud+json; version=1"].each_with_index do |accept, i|
        add_rule(accept, cidr: "10.0.#{i}.0/24", firewall_id: firewall.ubid)
        expect(last_response.status).to eq(200)
        expect(last_response["deprecation"]).to start_with("@")
      end
    end

    it "gives version 2 when asked, however the media range is written" do
      [v2, "APPLICATION/VND.UBICLOUD+JSON;VERSION=\"2\"", "application/json;q=0.5, application/vnd.ubicloud+json; q=1; version=2",
        "application/vnd.ubicloud+json;;version=2", "application/vnd.ubicloud+json; ; version=2"].each do |accept|
        add_rule(accept, firewall_id: firewall.ubid)
        expect(last_response).to have_api_error(400, "firewall_id was removed in API version 2: omit it")
      end
    end

    it "answers with application/json, varying on Accept" do
      list_vms(v2)
      expect(last_response.status).to eq(200)
      expect(last_response["content-type"]).to eq("application/json")
      expect(last_response["vary"]).to eq("accept")
      expect(last_response["deprecation"]).to be_nil
    end

    it "refuses the vendor media type without a well-formed version" do
      ["application/vnd.ubicloud+json", "application/vnd.ubicloud+json; version=two", "application/vnd.ubicloud+json; version=02", "application/vnd.ubicloud+json; version=0"].each do |accept|
        list_vms(accept)
        expect(last_response).to have_api_error(400, "Accept names application/vnd.ubicloud+json without a valid version; send application/vnd.ubicloud+json; version=2")
        expect(last_response["vary"]).to eq("accept")
      end
    end

    it "refuses a version that does not exist" do
      list_vms("application/vnd.ubicloud+json; version=3")
      expect(last_response).to have_api_error(406, "API version 3 does not exist; the versions are 1, 2")
    end

    it "reaches the routes that serve only a client accepting JSON" do
      pg = Prog::Postgres::PostgresResourceNexus.assemble(project_id: project.id, location_id: Location::HETZNER_FSN1_ID, name: "pg", target_vm_size: "standard-2", target_storage_size_gib: 128, target_version: "16").subject
      header "Accept", v2
      get "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/metrics"
      expect(last_response).to have_api_error(404, "Metrics are not configured for this instance")
    end

    it "is not read by the public IPv4 list" do
      header "Accept", "application/vnd.ubicloud+json; version=3"
      get "/ips-v4"
      expect(last_response.status).to eq(200)
      expect(last_response["vary"]).to be_nil
    end
  end

  describe "a deprecated input" do
    it "is accepted in version 1, logged, and warned of in the headers" do
      expect(Clog).to receive(:emit).with("deprecated api use", {deprecated_api_use: {project_id: project.ubid, version: 1, keys: ["createLocationFirewallRule.firewall_id"], refused: false, user_agent: ""}}).and_call_original
      add_rule("application/json", firewall_id: firewall.ubid)
      expect(last_response.status).to eq(200)
      expect(last_response["deprecation"]).to eq("@#{Time.utc(2026, 11, 2).to_i}")
      expect(last_response["warning"]).to eq('299 - "firewall_id is deprecated: omit it"')
    end

    it "is refused in version 2, naming what to do" do
      add_rule(v2, firewall_id: firewall.ubid, project_id: project.ubid)
      expect(last_response).to have_api_error(400, "firewall_id was removed in API version 2: omit it; project_id was removed in API version 2: omit it",
        {"firewall_id" => "firewall_id was removed in API version 2: omit it", "project_id" => "project_id was removed in API version 2: omit it"})
      expect(firewall.reload.firewall_rules).to be_empty
    end

    it "is never needed: a request without one gets no warning in either version" do
      ["application/json", v2].each_with_index do |accept, i|
        add_rule(accept, cidr: "10.0.#{i}.0/24")
        expect(last_response.status).to eq(200)
        expect(last_response["deprecation"]).to be_nil
      end
    end

    it "is refused in version 1 by the brownout, with the warning, at the configured share" do
      allow(Config).to receive(:api_deprecation_brownout).and_return({2 => 1.0})
      expect(Clog).to receive(:emit).with("deprecated api use", {deprecated_api_use: hash_including(refused: true)}).and_call_original
      add_rule("application/json", firewall_id: firewall.ubid)
      expect(last_response).to have_api_error(400, "firewall_id is deprecated: omit it. Requests that use a deprecated name will stop working; to warn of that, 100% of them are refused now, including this one.",
        {"firewall_id" => "firewall_id is deprecated: omit it"})
      expect(error["type"]).to eq("Deprecated")
      expect(last_response["warning"]).to eq('299 - "firewall_id is deprecated: omit it"')
      expect(firewall.reload.firewall_rules).to be_empty
    end

    it "is not refused by the brownout of another version" do
      allow(Config).to receive(:api_deprecation_brownout).and_return({3 => 1.0})
      add_rule("application/json", firewall_id: firewall.ubid)
      expect(last_response.status).to eq(200)
    end
  end

  describe "a renamed input" do
    def create_vm(accept, name: "vm", **body)
      header "Accept", accept
      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/vm/#{name}", {public_key: "ssh key", **body}.to_json
    end

    it "reaches the route under its new name in version 1, with the warning" do
      create_vm("application/json", enable_ip4: true)
      expect(last_response.status).to eq(200)
      expect(Vm.first.ip4_enabled).to be true
      expect(last_response["deprecation"]).to eq("@#{Time.utc(2026, 11, 2).to_i}")
      expect(last_response["warning"]).to eq('299 - "enable_ip4 is deprecated: use ip4_enabled instead"')
    end

    it "is refused together with its new name" do
      create_vm("application/json", enable_ip4: true, ip4_enabled: false)
      expect(last_response).to have_api_error(400, "enable_ip4 and ip4_enabled name one value; send only ip4_enabled", {"enable_ip4" => "send only ip4_enabled"})
      expect(Vm.count).to eq(0)
    end

    it "is refused in version 2, naming the new name" do
      create_vm(v2, enable_ip4: true)
      expect(last_response).to have_api_error(400, "enable_ip4 was removed in API version 2: use ip4_enabled instead")
    end

    it "is not needed: the new name works in both versions" do
      ["application/json", v2].each_with_index do |accept, i|
        create_vm(accept, name: "vm-#{i}", ip4_enabled: true)
        expect(last_response.status).to eq(200)
        expect(last_response["deprecation"]).to be_nil
        expect(Vm.first(name: "vm-#{i}").ip4_enabled).to be true
      end
    end
  end

  describe "a deprecated operation" do
    let(:pg) do
      Prog::Postgres::PostgresResourceNexus.assemble(project_id: project.id, location_id: Location::HETZNER_FSN1_ID, name: "pg", target_vm_size: "standard-2", target_storage_size_gib: 128, target_version: "16").subject
    end

    let(:promote_path) { "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/promote" }

    it "still answers in version 1, with the warning" do
      header "Accept", "application/json"
      post promote_path
      expect(last_response).to have_api_error(400, "Non read replica servers cannot be promoted.")
      expect(last_response["deprecation"]).to eq("@#{Time.utc(2026, 2, 19).to_i}")
      expect(last_response["warning"]).to eq('299 - "promotePostgresDatabase is deprecated: use promoteReadReplicaPostgresDatabase instead"')
    end

    it "is gone in version 2, naming its replacement" do
      header "Accept", v2
      post promote_path
      expect(last_response).to have_api_error(410, "promotePostgresDatabase was removed in API version 2: use promoteReadReplicaPostgresDatabase instead")
    end
  end

  it "keeps the CLI's own requests on the latest version" do
    project
    expect(Clog).not_to receive(:emit).with("deprecated api use", anything)
    header "Accept", "text/plain"
    post "/cli", {"argv" => ["pg", "#{TEST_LOCATION}/pg-cli", "create", "-f", "standard", "-s", "standard-2", "-S", "64"]}.to_json
    expect(last_response.status).to eq(200)
    expect(last_response["vary"]).to be_nil
    expect(PostgresResource.first(name: "pg-cli").target_vm_size).to eq("standard-2")
  end
end
