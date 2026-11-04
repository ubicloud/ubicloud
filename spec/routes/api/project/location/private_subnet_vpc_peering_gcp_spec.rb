# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Clover, "private subnet vpc peering in GCP" do
  let(:user) { create_account }

  let(:project) { project_with_default_policy(user) }

  let(:location) { Location[name: "gcp-us-central1"] }

  let(:ps) { gcp_subnet("test-ps") }

  let(:peerings_path) { subnet_peerings_path(ps) }

  let(:missing_ubid) { VpcPeering.generate_ubid.to_s }

  before do
    LocationCredentialGcp.create_with_id(location, project_id: "ubicloud-test", service_account_email: "test@ubicloud-test.iam.gserviceaccount.com", credentials_json: "{}")
  end

  def gcp_subnet(name, dedicated: true, is_management: false)
    Prog::Vnet::SubnetNexus.assemble(project.id, name:, location_id: location.id).subject.tap {
      Prog::Vnet::Gcp::VpcNexus.assemble(project.id, location.id, dedicated_for_subnet_id: (it.id if dedicated), is_management:).subject.add_private_subnet(it)
    }
  end

  def subnet_peerings_path(subnet)
    "/project/#{project.ubid}/location/#{location.display_name}/private-subnet/#{subnet.name}/vpc-peering"
  end

  def network_path(network, peer_project = "customer-project")
    "projects/#{peer_project}/global/networks/#{network}"
  end

  def assemble(network = "customer-vpc")
    Prog::Vnet::VpcPeeringNexus.assemble(ps, peer_account_id: "customer-project", peer_vpc_id: network_path(network)).subject
  end

  def create_body(**body)
    {peer_account_id: "customer-project", peer_vpc_id: "customer-vpc"}.merge(body).to_json
  end

  def all_routes(base = peerings_path)
    [
      [:get, base],
      [:post, base, create_body],
      [:get, "#{base}/#{missing_ubid}"],
      [:delete, "#{base}/#{missing_ubid}"],
    ]
  end

  def audit_logs(action)
    DB[:audit_log].where(action:, ubid_type: "px").select_map(:object_ids).map(&:to_a)
  end

  describe "unauthenticated" do
    it "cannot perform authenticated operations" do
      all_routes.each do |method, path, body|
        send(method, path, body)

        expect(last_response).to have_api_error(401, "must include personal access token in Authorization header")
      end
    end
  end

  describe "authenticated" do
    before do
      login_api
      allow(Config).to receive(:vpc_peering_enabled).and_return(true)
      project.set_ff_vpc_peering_gcp(true)
    end

    describe "gate" do
      it "is not found while VPC peering is disabled in the config" do
        allow(Config).to receive(:vpc_peering_enabled).and_return(false)
        all_routes.each do |method, path, body|
          send(method, path, body)

          expect(last_response).to have_api_error(404)
        end
      end

      it "is not found while the project has only the AWS feature flag" do
        project.set_ff_vpc_peering_gcp(false)
        project.set_ff_vpc_peering_aws(true)
        all_routes.each do |method, path, body|
          send(method, path, body)

          expect(last_response).to have_api_error(404)
        end
      end

      it "is not found for a private subnet without a VPC network of its own" do
        subnets = [
          gcp_subnet("shared-ps", dedicated: false),
          gcp_subnet("mgmt-ps", is_management: true),
          Prog::Vnet::SubnetNexus.assemble(project.id, name: "new-ps", location_id: location.id).subject,
        ]
        subnets.each do |subnet|
          all_routes(subnet_peerings_path(subnet)).each do |method, path, body|
            send(method, path, body)

            expect(last_response).to have_api_error(404)
          end
        end
        expect(VpcPeering.count).to eq 0
      end
    end

    describe "list" do
      it "lists the VPC peerings of the private subnet with their GCP details" do
        vp = assemble
        vp2 = assemble("other-vpc")
        vp.update(created_at: Time.now - 60)

        get peerings_path

        expect(last_response.status).to eq(200)
        gcp = {"local_project_id" => "ubicloud-test", "local_network_name" => ps.gcp_vpc.name}
        expect(JSON.parse(last_response.body)).to eq("items" => [
          {
            "id" => vp.ubid,
            "state" => "creating",
            "state_message" => nil,
            "private_subnet_id" => ps.ubid,
            "location" => "us-central1",
            "local_cidr" => ps.net4.to_s,
            "peer_account_id" => "customer-project",
            "peer_vpc_id" => "projects/customer-project/global/networks/customer-vpc",
            "peer_cidrs" => [],
            "created_at" => vp.created_at.utc.iso8601,
            "gcp" => gcp.merge("peering_name" => "ubicloud-#{vp.ubid}"),
          },
          {
            "id" => vp2.ubid,
            "state" => "creating",
            "state_message" => nil,
            "private_subnet_id" => ps.ubid,
            "location" => "us-central1",
            "local_cidr" => ps.net4.to_s,
            "peer_account_id" => "customer-project",
            "peer_vpc_id" => "projects/customer-project/global/networks/other-vpc",
            "peer_cidrs" => [],
            "created_at" => vp2.created_at.utc.iso8601,
            "gcp" => gcp.merge("peering_name" => "ubicloud-#{vp2.ubid}"),
          },
        ], "count" => 2)
      end
    end

    describe "create" do
      it "adds a peering to a network given by name, storing the network path" do
        post peerings_path, create_body

        expect(last_response.status).to eq(200)
        vp = ps.vpc_peerings.first
        expect(vp).to have_attributes(peer_account_id: "customer-project", peer_vpc_id: "projects/customer-project/global/networks/customer-vpc")
        expect(Strand[vp.id]).to have_attributes(prog: "Vnet::Gcp::VpcPeeringNexus", label: "start")
        expect(JSON.parse(last_response.body)).to include(
          "id" => vp.ubid,
          "state" => "creating",
          "peer_account_id" => "customer-project",
          "peer_vpc_id" => "projects/customer-project/global/networks/customer-vpc",
          "gcp" => {"local_project_id" => "ubicloud-test", "local_network_name" => ps.gcp_vpc.name, "peering_name" => "ubicloud-#{vp.ubid}"},
        )
        expect(audit_logs("create")).to eq([[vp.id, ps.id]])
      end

      it "accepts the network path and the self link, normalizing case and whitespace" do
        post peerings_path, create_body(peer_account_id: " Customer-Project ", peer_vpc_id: " Projects/customer-project/global/networks/Path-VPC ")
        expect(last_response.status).to eq(200)

        post peerings_path, create_body(peer_vpc_id: "https://www.googleapis.com/compute/v1/projects/customer-project/global/networks/link-vpc")
        expect(last_response.status).to eq(200)

        expect(ps.vpc_peerings.map { [it.peer_account_id, it.peer_vpc_id] }).to contain_exactly(
          ["customer-project", "projects/customer-project/global/networks/path-vpc"],
          ["customer-project", "projects/customer-project/global/networks/link-vpc"],
        )
      end

      it "adds a second peering to another network" do
        assemble

        post peerings_path, create_body(peer_vpc_id: "other-vpc")

        expect(last_response.status).to eq(200)
        expect(ps.vpc_peerings.map(&:peer_vpc_id)).to contain_exactly(network_path("customer-vpc"), network_path("other-vpc"))
      end

      it "rejects a network path that names another project" do
        post peerings_path, create_body(peer_vpc_id: network_path("customer-vpc", "other-project"))

        expect(last_response).to have_api_error(400, "Validation failed for following fields: peer_vpc_id", {"peer_vpc_id" => "The network path names project other-project, not customer-project."})
        expect(ps.vpc_peerings_dataset.count).to eq 0
      end

      it "rejects an invalid project ID and network name together" do
        post peerings_path, create_body(peer_account_id: "123456789012", peer_vpc_id: "bad;network")

        expect(last_response).to have_api_error(400, "Validation failed for following fields: peer_account_id, peer_vpc_id", {
          "peer_account_id" => "GCP project ID must be 6 to 30 lowercase letters, digits or hyphens, start with a letter and not end with a hyphen, such as my-project-123. Use the project ID, not the project number.",
          "peer_vpc_id" => "VPC network name must be 1 to 63 lowercase letters, digits or hyphens, start with a letter and not end with a hyphen.",
        })
        expect(ps.vpc_peerings_dataset.count).to eq 0
      end

      it "rejects the aws object" do
        post peerings_path, create_body(aws: {peer_region: "us-east-1"})

        expect(last_response).to have_api_error(400, "Validation failed for following fields: aws", {"aws" => "Only valid in AWS locations."})
        expect(ps.vpc_peerings_dataset.count).to eq 0
      end

      it "rejects the GCP project of the Ubicloud-managed location" do
        post peerings_path, create_body(peer_account_id: "ubicloud-test", peer_vpc_id: "default")

        expect(last_response).to have_api_error(400, "Validation failed for following fields: peer_account_id", {"peer_account_id" => "ubicloud-test is Ubicloud's GCP project. Enter the ID of the GCP project that owns your VPC network."})
        expect(ps.vpc_peerings_dataset.count).to eq 0
      end

      it "rejects a Ubicloud VPC network" do
        other_project = Project.create(name: "other-prj")
        other_location = Location.create(name: "gcp-us-east4", provider: "gcp", project_id: other_project.id, display_name: "gcp-us-east4", ui_name: "gcp-us-east4", visible: true)
        LocationCredentialGcp.create_with_id(other_location, project_id: "byoc-project", service_account_email: "test@byoc-project.iam.gserviceaccount.com", credentials_json: "{}")
        vpc_name = Prog::Vnet::Gcp::VpcNexus.assemble(other_project.id, other_location.id).subject.name

        post peerings_path, create_body(peer_account_id: "byoc-project", peer_vpc_id: vpc_name)

        expect(last_response).to have_api_error(400, "Validation failed for following fields: peer_vpc_id", {"peer_vpc_id" => "#{network_path(vpc_name, "byoc-project")} is a Ubicloud VPC network. Enter a VPC network in your own GCP project."})
        expect(ps.vpc_peerings_dataset.count).to eq 0
      end

      it "rejects a second peering to the same network" do
        assemble

        post peerings_path, create_body

        expect(last_response).to have_api_error(400, "Validation failed for following fields: peer_vpc_id", {"peer_vpc_id" => "This private subnet already has a VPC peering with #{network_path("customer-vpc")}. Delete it first. If you just deleted it, wait until it disappears."})
        expect(ps.vpc_peerings_dataset.count).to eq 1
      end

      it "rejects a private subnet that is being deleted" do
        ps.incr_destroy

        post peerings_path, create_body

        expect(last_response).to have_api_error(400, "Private subnet 'test-ps' is being deleted")
        expect(audit_logs("create")).to eq([])
      end
    end

    describe "show" do
      it "shows a VPC peering of the private subnet" do
        vp = assemble
        vp.update(state: "active", peer_cidrs: Sequel.pg_array(["10.200.0.0/20"], :cidr))

        get "#{peerings_path}/#{vp.ubid}"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)).to include(
          "id" => vp.ubid,
          "state" => "active",
          "peer_cidrs" => ["10.200.0.0/20"],
          "gcp" => {"local_project_id" => "ubicloud-test", "local_network_name" => ps.gcp_vpc.name, "peering_name" => "ubicloud-#{vp.ubid}"},
        )
      end
    end

    describe "delete" do
      it "marks the VPC peering for deletion" do
        vp = assemble

        delete "#{peerings_path}/#{vp.ubid}"

        expect(last_response.status).to eq(204)
        expect(vp.destroy_set?(cached: false)).to be true
        expect(audit_logs("destroy")).to eq([[vp.id, ps.id]])
      end

      it "succeeds for an unknown VPC peering" do
        delete "#{peerings_path}/#{missing_ubid}"

        expect(last_response.status).to eq(204)
        expect(audit_logs("destroy")).to eq([])
      end
    end

    it "refuses to delete the private subnet while it has a VPC peering" do
      assemble

      delete "/project/#{project.ubid}/location/#{location.display_name}/private-subnet/#{ps.name}"

      expect(last_response).to have_api_error(409, "Private subnet 'test-ps' has VPC peerings, first, delete them.")
      expect(ps.destroy_set?(cached: false)).to be false
    end

    it "does not find the private subnet of another project" do
      other = user.create_project_with_default_policy("other-project")

      get peerings_path.sub(project.ubid, other.ubid)

      expect(last_response).to have_api_error(404)
    end

    describe "with only PrivateSubnet:view" do
      before do
        ps
        AccessControlEntry.dataset.destroy
        [user.id, @pat.id].each do
          AccessControlEntry.create(project_id: project.id, subject_id: it, action_id: ActionType::NAME_MAP["PrivateSubnet:view"])
        end
      end

      it "can list and show VPC peerings but not create or delete them" do
        vp = assemble

        get peerings_path
        expect(last_response.status).to eq(200)

        get "#{peerings_path}/#{vp.ubid}"
        expect(last_response.status).to eq(200)

        post peerings_path, create_body(peer_vpc_id: "other-vpc")
        expect(last_response).to have_api_error(403)

        delete "#{peerings_path}/#{vp.ubid}"
        expect(last_response).to have_api_error(403)
        expect(vp.destroy_set?(cached: false)).to be false
        expect(ps.vpc_peerings_dataset.count).to eq 1
      end
    end
  end
end
