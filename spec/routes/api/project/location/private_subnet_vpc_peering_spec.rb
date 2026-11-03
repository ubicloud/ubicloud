# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Clover, "private subnet vpc peering" do
  let(:user) { create_account }

  let(:project) { project_with_default_policy(user) }

  let(:location) {
    Location.create(name: "us-west-2", provider: "aws", display_name: "aws-us-west-2", ui_name: "aws-us-west-2", visible: true).tap {
      LocationAz.create(location_id: it.id, az: "a", zone_id: "usw2-az1")
    }
  }

  let(:ps) {
    Prog::Vnet::SubnetNexus.assemble(project.id, name: "test-ps", location_id: location.id).subject.tap {
      it.private_subnet_aws_resource.update(vpc_id: "vpc-0aaaaaaaaaaaaaaaa")
    }
  }

  let(:peerings_path) { "/project/#{project.ubid}/location/#{location.display_name}/private-subnet/#{ps.name}/vpc-peering" }

  let(:missing_ubid) { VpcPeering.generate_ubid.to_s }

  def assemble(peer_vpc_id = "vpc-0bbbbbbbbbbbbbbbb")
    Prog::Vnet::VpcPeeringNexus.assemble(ps, peer_account_id: "111122223333", peer_vpc_id:, aws: {peer_region: "us-east-1"}).subject
  end

  def create_body(**body)
    {peer_account_id: "111122223333", peer_vpc_id: "vpc-0bbbbbbbbbbbbbbbb"}.merge(body).to_json
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
      project.set_ff_vpc_peering_aws(true)
    end

    describe "gate" do
      it "is not found while VPC peering is disabled in the config" do
        allow(Config).to receive(:vpc_peering_enabled).and_return(false)
        all_routes.each do |method, path, body|
          send(method, path, body)

          expect(last_response).to have_api_error(404)
        end
      end

      it "is not found while the project does not have the feature flag" do
        project.set_ff_vpc_peering_aws(false)
        all_routes.each do |method, path, body|
          send(method, path, body)

          expect(last_response).to have_api_error(404)
        end
      end

      it "is not found for a private subnet outside AWS" do
        metal_ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "metal-ps").subject
        all_routes("/project/#{project.ubid}/location/#{metal_ps.display_location}/private-subnet/#{metal_ps.name}/vpc-peering").each do |method, path, body|
          send(method, path, body)

          expect(last_response).to have_api_error(404)
        end
      end
    end

    describe "list" do
      it "lists the VPC peerings of the private subnet" do
        get peerings_path

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)).to eq("items" => [], "count" => 0)

        vp = assemble
        get peerings_path

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)).to eq("items" => [{
          "id" => vp.ubid,
          "state" => "creating",
          "state_message" => nil,
          "private_subnet_id" => ps.ubid,
          "location" => "aws-us-west-2",
          "local_cidr" => ps.net4.to_s,
          "peer_account_id" => "111122223333",
          "peer_vpc_id" => "vpc-0bbbbbbbbbbbbbbbb",
          "peer_cidrs" => [],
          "created_at" => vp.created_at.utc.iso8601,
          "aws" => {
            "peer_region" => "us-east-1",
            "peering_connection_id" => nil,
            "requester_account_id" => nil,
            "requester_vpc_id" => "vpc-0aaaaaaaaaaaaaaaa",
            "expires_at" => nil,
          },
        }], "count" => 1)

        vp2 = assemble("vpc-0cccccccccccccccc")
        vp.update(created_at: Time.now - 60)
        get peerings_path

        expect(last_response.status).to eq(200)
        body = JSON.parse(last_response.body)
        expect(body["count"]).to eq(2)
        expect(body["items"].map { it["id"] }).to eq([vp.ubid, vp2.ubid])
      end

      it "reaches the private subnet of a PostgreSQL database by its name" do
        pg_ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "#{PostgresResource.generate_ubid}-subnet", location_id: location.id).subject

        get "/project/#{project.ubid}/location/#{location.display_name}/private-subnet/#{pg_ps.name}/vpc-peering"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["count"]).to eq(0)
      end
    end

    describe "create" do
      it "requests a peering in the region of the location by default" do
        post peerings_path, create_body

        expect(last_response.status).to eq(200)
        vp = ps.vpc_peerings.first
        expect(Strand[vp.id].label).to eq("start")
        expect(vp.vpc_peering_aws_resource.peer_region).to eq("us-west-2")
        body = JSON.parse(last_response.body)
        expect(body).to include("id" => vp.ubid, "state" => "creating", "peer_account_id" => "111122223333", "peer_vpc_id" => "vpc-0bbbbbbbbbbbbbbbb")
        expect(body["aws"]).to include("peer_region" => "us-west-2")
        expect(audit_logs("create")).to eq([[vp.id, ps.id]])
      end

      it "requests a peering in the given region, normalizing the account and VPC IDs and the region" do
        post peerings_path, create_body(peer_account_id: "1111 2222-3333", peer_vpc_id: " VPC-0BBBBBBBBBBBBBBBB ", aws: {peer_region: " EU-Central-1 "})

        expect(last_response.status).to eq(200)
        expect(ps.vpc_peerings.first).to have_attributes(peer_account_id: "111122223333", peer_vpc_id: "vpc-0bbbbbbbbbbbbbbbb")
        expect(JSON.parse(last_response.body)["aws"]["peer_region"]).to eq("eu-central-1")
      end

      it "rejects invalid input with every field's message" do
        post peerings_path, create_body(peer_account_id: "1234", peer_vpc_id: "vpc-xyz", aws: {peer_region: "cn-north-1"})

        expect(last_response).to have_api_error(400, "Validation failed for following fields: peer_account_id, peer_vpc_id, aws.peer_region", {
          "peer_account_id" => "AWS account ID must be 12 digits, such as 123456789012. It is in the account menu at the top right of the AWS console.",
          "peer_vpc_id" => "VPC ID must look like vpc-0123456789abcdef0. It is under Your VPCs in the AWS VPC console.",
          "aws.peer_region" => "\"cn-north-1\" is not an AWS region. Use a region code such as us-east-1.",
        })
        expect(ps.vpc_peerings_dataset.count).to eq(0)
      end

      it "rejects a Ubicloud VPC as the peer" do
        post peerings_path, create_body(peer_vpc_id: "vpc-0aaaaaaaaaaaaaaaa")

        expect(last_response).to have_api_error(400, "Validation failed for following fields: peer_vpc_id", {"peer_vpc_id" => "vpc-0aaaaaaaaaaaaaaaa is a Ubicloud VPC. Enter the ID of a VPC in your own AWS account."})
        expect(ps.vpc_peerings_dataset.count).to eq(0)
      end

      it "surfaces the per private subnet cap" do
        10.times { VpcPeering.create(private_subnet_id: ps.id, peer_account_id: "111122223333", peer_vpc_id: "vpc-0#{it}aaaaaaaaaaaaaaa", state: "active") }

        post peerings_path, create_body

        expect(last_response).to have_api_error(400, "Private subnet 'test-ps' already has 10 VPC peerings, the maximum. Delete one first. If you just deleted one, wait until it disappears.")
        expect(audit_logs("create")).to eq([])
      end
    end

    describe "show" do
      it "shows a VPC peering of the private subnet" do
        vp = assemble
        vp.vpc_peering_aws_resource.update(peering_connection_id: "pcx-0123456789abcdef0", requester_account_id: "999988887777", expires_at: Time.utc(2026, 10, 30, 12))
        vp.update(state: "active", peer_cidrs: Sequel.pg_array(["10.200.0.0/16"], :cidr), state_message: "Not routed: 8.8.0.0/16.")

        get "#{peerings_path}/#{vp.ubid}"

        expect(last_response.status).to eq(200)
        body = JSON.parse(last_response.body)
        expect(body).to include("id" => vp.ubid, "state" => "active", "state_message" => "Not routed: 8.8.0.0/16.", "peer_cidrs" => ["10.200.0.0/16"])
        expect(body["aws"]).to eq(
          "peer_region" => "us-east-1",
          "peering_connection_id" => "pcx-0123456789abcdef0",
          "requester_account_id" => "999988887777",
          "requester_vpc_id" => "vpc-0aaaaaaaaaaaaaaaa",
          "expires_at" => "2026-10-30T12:00:00Z",
        )
      end

      it "does not find an unknown VPC peering" do
        get "#{peerings_path}/#{missing_ubid}"

        expect(last_response).to have_api_error(404)
      end

      it "does not find a VPC peering of another private subnet" do
        vp = assemble
        other_ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "other-ps", location_id: location.id).subject

        get "/project/#{project.ubid}/location/#{location.display_name}/private-subnet/#{other_ps.name}/vpc-peering/#{vp.ubid}"

        expect(last_response).to have_api_error(404)
      end
    end

    describe "delete" do
      it "marks the VPC peering for deletion" do
        vp = assemble

        delete "#{peerings_path}/#{vp.ubid}"

        expect(last_response.status).to eq(204)
        expect(vp.destroy_set?(cached: false)).to be true
        expect(audit_logs("destroy")).to eq([[vp.id, ps.id]])

        get "#{peerings_path}/#{vp.ubid}"
        expect(JSON.parse(last_response.body)["state"]).to eq("deleting")
      end

      it "succeeds for an unknown VPC peering" do
        delete "#{peerings_path}/#{missing_ubid}"

        expect(last_response.status).to eq(204)
      end

      it "does not delete a VPC peering of another private subnet" do
        vp = assemble
        other_ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "other-ps", location_id: location.id).subject

        delete "/project/#{project.ubid}/location/#{location.display_name}/private-subnet/#{other_ps.name}/vpc-peering/#{vp.ubid}"

        expect(last_response.status).to eq(204)
        expect(vp.destroy_set?(cached: false)).to be false
        expect(audit_logs("destroy")).to eq([])
      end
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

        post peerings_path, create_body(peer_vpc_id: "vpc-0cccccccccccccccc")
        expect(last_response).to have_api_error(403)

        delete "#{peerings_path}/#{vp.ubid}"
        expect(last_response).to have_api_error(403)
        expect(vp.destroy_set?(cached: false)).to be false
      end
    end
  end
end
