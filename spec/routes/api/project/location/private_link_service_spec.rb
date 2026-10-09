# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Clover, "private-link-service" do
  let(:user) { create_account }
  let(:project) { project_with_default_policy(user) }

  let(:aws_location) { create_private_location(project:) }
  let(:ps) { Prog::Vnet::SubnetNexus.assemble(project.id, name: "ps-aws", location_id: aws_location.id).subject }
  let(:pg) do
    Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: project.id, location_id: aws_location.id, name: "pg-aws",
      target_vm_size: "standard-2", target_storage_size_gib: 128, target_version: "16",
    ).subject
  end
  let(:ec2) { Aws::EC2::Client.new(stub_responses: true) }

  def assemble_pls(name, subnet = ps, **)
    Prog::Vnet::PrivateLinkServiceNexus.assemble(
      project_id: project.id, private_subnet_id: subnet.id, name:, allowed_principals: ["arn:aws:iam::123456789012:root"],
      postgres_resource_id: nil, ports: [[5432, 5432], [6432, 6432]], ip_address_type: "ipv4", aws_supported_regions: [], aws_allowed_vpc_endpoints: [], **,
    ).subject
  end

  def base
    "/project/#{project.ubid}/location/#{aws_location.display_name}/private-link-service"
  end

  def pg_base
    "/project/#{project.ubid}/location/#{aws_location.display_name}/postgres/#{pg.name}/private-link-service"
  end

  def body
    JSON.parse(last_response.body)
  end

  # A replacement policy needs an entry for the account and for its personal access token.
  def grant(action, object_id: nil)
    [user.id, @pat.id].each do |subject_id|
      AccessControlEntry.create(project_id: project.id, subject_id:, action_id: ActionType::NAME_MAP[action], object_id:)
    end
  end

  describe "unauthenticated" do
    it "cannot perform authenticated operations" do
      project.set_ff_private_link_service_aws(true)
      allow(Config).to receive(:postgres_service_project_id).and_return(Project.create(name: "postgres-service").id)
      pls = assemble_pls("pl-1")
      [
        [:get, "/project/#{project.ubid}/private-link-service"],
        [:get, base],
        [:post, "#{base}/pl-2", {private_subnet_id: ps.ubid, aws: {allowed_principals: ["*"]}}],
        [:get, "#{base}/#{pls.name}"],
        [:patch, "#{base}/#{pls.name}", {aws: {allowed_vpc_endpoints: []}}],
        [:delete, "#{base}/#{pls.name}"],
        [:get, pg_base],
        [:post, pg_base, {name: "pl-3", aws: {allowed_principals: ["*"]}}],
      ].each do |method, path, params|
        send(method, path, params&.to_json)
        expect(last_response).to have_api_error(401, "must include personal access token in Authorization header")
      end
    end
  end

  describe "authenticated" do
    # login_api before anything references project: the token is issued with the project.
    before do
      login_api
      project.set_ff_private_link_service_aws(true)
      allow(Config).to receive(:postgres_service_project_id).and_return(Project.create(name: "postgres-service").id)
    end

    describe "feature flag" do
      it "returns 404 everywhere while the provider is not enabled for the project" do
        pls = assemble_pls("pl-1")
        project.set_ff_private_link_service_aws(false)

        get "/project/#{project.ubid}/private-link-service"
        expect(last_response.status).to eq 404
        get base
        expect(last_response.status).to eq 404
        get "#{base}/#{pls.name}"
        expect(last_response.status).to eq 404
        get pg_base
        expect(last_response).to have_api_error(404, "private link services are not enabled for this project")
      end
    end

    describe "list" do
      it "lists the project's services, and only the location's under the location" do
        assemble_pls("pl-1")
        assemble_pls("pl-2")

        get "/project/#{project.ubid}/private-link-service"
        expect(last_response.status).to eq 200
        expect(body["items"].map { it["name"] }.sort).to eq ["pl-1", "pl-2"]
        expect(body["count"]).to eq 2

        get base
        expect(last_response.status).to eq 200
        expect(body["items"].map { it["name"] }.sort).to eq ["pl-1", "pl-2"]
        expect(body["items"].first.keys).not_to include("aws")

        get "/project/#{project.ubid}/location/#{Location[Location::HETZNER_FSN1_ID].display_name}/private-link-service"
        expect(last_response.status).to eq 404
      end

      it "lists only the services the user may view" do
        pls_one = assemble_pls("pl-1")
        assemble_pls("pl-2")
        AccessControlEntry.dataset.destroy
        grant("PrivateLinkService:view", object_id: pls_one.id)

        get base
        expect(last_response.status).to eq 200
        expect(body["items"].map { it["name"] }).to eq ["pl-1"]
      end
    end

    describe "create by name" do
      it "creates a service in the subnet with the PostgreSQL defaults and shows it" do
        post "#{base}/pl-1", {private_subnet_id: ps.ubid, aws: {allowed_principals: [" arn:aws:iam::222222222222:root ", "arn:aws:iam::222222222222:root"]}}.to_json

        expect(last_response.status).to eq 200
        pls = PrivateLinkService.first(name: "pl-1")
        expect(pls.private_subnet_id).to eq ps.id
        expect(pls.strand.label).to eq "start"
        expect(body["id"]).to eq pls.ubid
        expect(body["state"]).to eq "creating"
        expect(body["private_subnet"]).to eq "ps-aws"
        expect(body["postgres_resource"]).to be_nil
        expect(body["allowed_principals"]).to eq ["arn:aws:iam::222222222222:root"]
        expect(body["ports"]).to eq [{"port" => 5432, "target_port" => 5432}, {"port" => 6432, "target_port" => 6432}]
        expect(body["private_dns_name"]).to be_nil
        expect(body["private_hostname"]).to be_nil
        expect(body["aws"]).to eq({"service_name" => nil, "service_id" => nil, "supported_regions" => [], "allowed_vpc_endpoints" => [], "registered_target_ips" => [], "private_dns_verification_state" => nil})
        expect(DB[:audit_log].where(ubid_type: "pn", action: "create").count).to eq 1
      end

      it "attaches a PostgreSQL resource from the subnet and takes custom ports and approved endpoints" do
        post "#{base}/pl-pg", {private_subnet_id: pg.private_subnet.ubid, postgres_resource_id: pg.ubid, ports: [15432], target_ports: [5432], ip_address_type: "dual", aws: {allowed_principals: ["*"], allowed_vpc_endpoints: [{vpc_endpoint_id: " vpce-0123456789abcdef1 ", description: " analytics team "}, {vpc_endpoint_id: "vpce-0123456789abcdef0"}]}}.to_json

        expect(last_response.status).to eq 200
        expect(body["postgres_resource"]).to eq pg.ubid
        expect(body["ports"]).to eq [{"port" => 15432, "target_port" => 5432}]
        expect(body["ip_address_type"]).to eq "dual"
        expect(body["aws"]["allowed_vpc_endpoints"]).to eq [{"vpc_endpoint_id" => "vpce-0123456789abcdef0", "description" => ""}, {"vpc_endpoint_id" => "vpce-0123456789abcdef1", "description" => "analytics team"}]
        expect(body["private_dns_name"]).to be_nil
        expect(body["private_hostname"]).to eq pg.private_hostname

        post "#{base}/pl-zero", {private_subnet_id: pg.private_subnet.ubid, ports: [0], target_ports: [5432], aws: {allowed_principals: ["*"]}}.to_json
        expect(last_response).to have_api_error(400, "Validation failed for following fields: ports")
        post "#{base}/pl-zero", {private_subnet_id: pg.private_subnet.ubid, ports: [5432], target_ports: [-1], aws: {allowed_principals: ["*"]}}.to_json
        expect(last_response).to have_api_error(400, "Validation failed for following fields: ports")
        expect(PrivateLinkService.where(name: "pl-zero").count).to eq 0

        post "#{base}/pl-bad", {private_subnet_id: pg.private_subnet.ubid, aws: {allowed_principals: ["*"], allowed_vpc_endpoints: [{vpc_endpoint_id: "vpce-xyz"}, {vpc_endpoint_id: "i-0123456789abcdef0", description: "x"}]}}.to_json
        expect(last_response).to have_api_error(400, "Validation failed for following fields: allowed_vpc_endpoints")
        expect(JSON.parse(last_response.body).dig("error", "details", "allowed_vpc_endpoints")).to end_with("invalid: vpce-xyz, i-0123456789abcdef0")
      end

      it "rejects a subnet outside the location, a resource outside the subnet, a taken name and a bad region" do
        other = Prog::Vnet::SubnetNexus.assemble(project.id, name: "ps-hetzner", location_id: Location::HETZNER_FSN1_ID).subject
        post "#{base}/pl-1", {private_subnet_id: other.ubid, aws: {allowed_principals: ["*"]}}.to_json
        expect(last_response).to have_api_error(400, "Validation failed for following fields: private_subnet_id")

        post "#{base}/pl-1", {private_subnet_id: ps.ubid, postgres_resource_id: pg.ubid, aws: {allowed_principals: ["*"]}}.to_json
        expect(last_response).to have_api_error(400, "Validation failed for following fields: postgres_resource_id")

        assemble_pls("taken")
        post "#{base}/taken", {private_subnet_id: ps.ubid, aws: {allowed_principals: ["*"]}}.to_json
        expect(last_response).to have_api_error(400, "Validation failed for following fields: name")

        post "#{base}/pl-1", {private_subnet_id: ps.ubid, aws: {allowed_principals: ["arn:aws:iam::123456789012:group/admins"]}}.to_json
        expect(last_response).to have_api_error(400, "Validation failed for following fields: allowed_principals")
        expect(JSON.parse(last_response.body).dig("error", "details", "allowed_principals")).to end_with("invalid: arn:aws:iam::123456789012:group/admins")

        post "#{base}/pl-1", {private_subnet_id: ps.ubid, aws: {allowed_principals: ["*"], supported_regions: ["mars-1"]}}.to_json
        expect(last_response).to have_api_error(400, "Validation failed for following fields: supported_regions")
        expect(PrivateLinkService.count).to eq 1
      end

      it "requires PrivateLinkService:create" do
        AccessControlEntry.dataset.destroy
        grant("PrivateSubnet:edit")

        post "#{base}/pl-1", {private_subnet_id: ps.ubid, aws: {allowed_principals: ["*"]}}.to_json
        expect(last_response.status).to eq 403
      end
    end

    describe "show" do
      it "shows a service by name or id with its provider state, and 404s otherwise" do
        pls = assemble_pls("pl-1")
        aws = pls.private_link_service_aws_resource
        aws.update(service_name: "com.amazonaws.vpce.us-west-2.vpce-svc-0123", service_id: "vpce-svc-0123", registered_target_ips: Sequel.pg_array(["10.0.0.5"], :inet), supported_regions: Sequel.pg_array(["eu-west-1"], :text))
        PrivateLinkServiceAwsAllowedEndpoint.create(private_link_service_aws_resource_id: aws.id, vpc_endpoint_id: "vpce-a", description: "analytics team")

        get "#{base}/pl-1"
        expect(last_response.status).to eq 200
        expect(body["id"]).to eq pls.ubid
        expect(body["location"]).to eq aws_location.display_name
        expect(body["aws"]).to eq({
          "service_name" => "com.amazonaws.vpce.us-west-2.vpce-svc-0123", "service_id" => "vpce-svc-0123",
          "supported_regions" => ["eu-west-1"], "allowed_vpc_endpoints" => [{"vpc_endpoint_id" => "vpce-a", "description" => "analytics team"}],
          "registered_target_ips" => ["10.0.0.5"], "private_dns_verification_state" => nil,
        })

        get "#{base}/#{pls.ubid}"
        expect(last_response.status).to eq 200
        expect(body["name"]).to eq "pl-1"

        get "#{base}/nope"
        expect(last_response.status).to eq 404
      end
    end

    describe "update" do
      let(:pls) do
        pls = assemble_pls("pl-1")
        pls.strand.update(label: "wait")
        pls
      end

      before do
        allow(Aws::EC2::Client).to receive(:new).and_return(ec2)
        ec2.stub_responses(:describe_regions, regions: %w[us-west-2 eu-west-1].map { {region_name: it} })
      end

      it "changes the settings that are given and leaves the others alone" do
        patch "#{base}/#{pls.name}", {aws: {allowed_principals: ["arn:aws:iam::333333333333:role/app"]}}.to_json
        expect(last_response.status).to eq 200
        expect(body["allowed_principals"]).to eq ["arn:aws:iam::333333333333:role/app"]
        expect(pls.reload.update_permissions_set?).to be true
        expect(pls.reconcile_set?).to be false
        expect(pls.reconcile_connections_set?).to be false

        patch "#{base}/#{pls.name}", {aws: {supported_regions: ["eu-west-1"]}}.to_json
        expect(last_response.status).to eq 200
        expect(body["aws"]["supported_regions"]).to eq ["eu-west-1"]
        expect(body["allowed_principals"]).to eq ["arn:aws:iam::333333333333:role/app"]
        expect(pls.reload.reconcile_set?).to be true

        patch "#{base}/#{pls.name}", {aws: {supported_regions: []}}.to_json
        expect(last_response.status).to eq 200
        expect(body["aws"]["supported_regions"]).to eq []

        patch "#{base}/#{pls.name}", {aws: {allowed_principals: ["not-an-arn"]}}.to_json
        expect(last_response).to have_api_error(400, "Validation failed for following fields: allowed_principals")
        expect(pls.reload.allowed_principals).to eq ["arn:aws:iam::333333333333:role/app"]

        patch "#{base}/#{pls.name}", {aws: {allowed_vpc_endpoints: [{vpc_endpoint_id: "vpce-0123456789abcdef0", description: "analytics team"}]}}.to_json
        expect(last_response.status).to eq 200
        expect(body["aws"]["allowed_vpc_endpoints"]).to eq [{"vpc_endpoint_id" => "vpce-0123456789abcdef0", "description" => "analytics team"}]
        expect(body["allowed_principals"]).to eq ["arn:aws:iam::333333333333:role/app"]
        expect(pls.reload.reconcile_connections_set?).to be true

        patch "#{base}/#{pls.name}", {aws: {allowed_vpc_endpoints: [{vpc_endpoint_id: "nope"}]}}.to_json
        expect(last_response).to have_api_error(400, "Validation failed for following fields: allowed_vpc_endpoints")
        expect(pls.reload.private_link_service_aws_resource.allowed_endpoints.map(&:vpc_endpoint_id)).to eq ["vpce-0123456789abcdef0"]
        expect(DB[:audit_log].where(ubid_type: "pn", action: "update").count).to eq 4
      end

      it "changes nothing when the body carries no setting" do
        patch "#{base}/#{pls.name}", {}.to_json
        expect(last_response.status).to eq 200
        expect(body["allowed_principals"]).to eq ["arn:aws:iam::123456789012:root"]
        expect(pls.reload.update_permissions_set?).to be false
        expect(pls.reconcile_set?).to be false
        expect(pls.reconcile_connections_set?).to be false
      end

      it "rejects a region the account has not enabled" do
        patch "#{base}/#{pls.name}", {aws: {supported_regions: ["ap-south-1"]}}.to_json
        expect(last_response).to have_api_error(400, "Validation failed for following fields: supported_regions")
        expect(body.dig("error", "details", "supported_regions")).to eq "Not enabled in the provider's AWS account: ap-south-1"
      end

      it "reports a failed check against the provider account as a field error" do
        ec2.stub_responses(:describe_regions, "AuthFailure")
        patch "#{base}/#{pls.name}", {aws: {supported_regions: ["eu-west-1"]}}.to_json
        expect(last_response).to have_api_error(400, "Validation failed for following fields: supported_regions")
        expect(body.dig("error", "details", "supported_regions")).to eq "Could not check the regions enabled in the provider's AWS account, try again"
        expect(pls.reload.reconcile_set?).to be false
      end

      it "rejects a blank principal as a bad request" do
        patch "#{base}/#{pls.name}", {aws: {allowed_principals: [""]}}.to_json
        expect(last_response.status).to eq 400
        expect(body.dig("error", "type")).to eq "InvalidRequest"
        expect(pls.reload.allowed_principals).to eq ["arn:aws:iam::123456789012:root"]
      end

      it "requires PrivateLinkService:edit" do
        AccessControlEntry.dataset.destroy
        grant("PrivateLinkService:view")

        patch "#{base}/#{pls.name}", {aws: {allowed_vpc_endpoints: []}}.to_json
        expect(last_response.status).to eq 403
      end
    end

    describe "delete" do
      it "schedules the service for deletion" do
        pls = assemble_pls("pl-1")
        pls.strand.update(label: "wait")

        delete "#{base}/#{pls.name}"
        expect(last_response.status).to eq 204
        expect(pls.reload.destroy_set?).to be true
        expect(DB[:audit_log].where(ubid_type: "pn", action: "destroy").count).to eq 1
      end

      it "requires PrivateLinkService:delete" do
        pls = assemble_pls("pl-1")
        AccessControlEntry.dataset.destroy
        grant("PrivateLinkService:edit")

        delete "#{base}/#{pls.name}"
        expect(last_response.status).to eq 403
        expect(pls.reload.destroy_set?).to be false
      end
    end

    describe "under a PostgreSQL resource" do
      it "shows the service exposing the resource" do
        assemble_pls("pl-pg", pg.private_subnet, postgres_resource_id: pg.id)
        assemble_pls("pl-other", pg.private_subnet)

        get pg_base
        expect(last_response.status).to eq 200
        expect(body["name"]).to eq "pl-pg"
        expect(body["postgres_resource"]).to eq pg.ubid
        expect(body["allowed_principals"]).to eq ["arn:aws:iam::123456789012:root"]
        expect(body["aws"].keys).to include("service_name", "allowed_vpc_endpoints")
      end

      it "returns 404 while the resource has no service" do
        get pg_base
        expect(last_response.status).to eq 404
      end

      it "refuses a second service for the resource" do
        assemble_pls("pl-pg", pg.private_subnet, postgres_resource_id: pg.id)

        post pg_base, {name: "pl-second", aws: {allowed_principals: ["*"]}}.to_json
        expect(last_response).to have_api_error(400, "Validation failed for following fields: postgres_resource_id", {"postgres_resource_id" => "PostgreSQL resource already has a private link service"})
        expect(PrivateLinkService.where(name: "pl-second")).to be_empty
      end

      it "creates a service attached to the resource in its subnet" do
        post pg_base, {name: "pl-pg", aws: {allowed_principals: ["*"]}}.to_json

        expect(last_response.status).to eq 200
        expect(body["name"]).to eq "pl-pg"
        expect(body["postgres_resource"]).to eq pg.ubid
        expect(body["private_subnet"]).to eq pg.private_subnet.name
        expect(body["ports"].map { it["port"] }).to eq [5432, 6432]
        pls = PrivateLinkService.first(name: "pl-pg")
        expect(pls.target_vms.map(&:id)).to eq [pg.representative_server.vm_id]
      end

      it "requires Postgres:edit on the resource and PrivateLinkService:create on the project" do
        AccessControlEntry.dataset.destroy
        grant("Postgres:view")
        grant("PrivateLinkService:create")
        post pg_base, {name: "pl-pg", aws: {allowed_principals: ["*"]}}.to_json
        expect(last_response.status).to eq 403

        grant("Postgres:edit")
        post pg_base, {name: "pl-pg", aws: {allowed_principals: ["*"]}}.to_json
        expect(last_response.status).to eq 200
      end
    end
  end
end
