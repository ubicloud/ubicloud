# frozen_string_literal: true

RSpec.describe Prog::Vnet::VpcPeeringNexus do
  let(:project) { Project.create(name: "test-prj") }
  let(:location) { aws_location("us-west-2") }
  let(:ps) { aws_subnet(location, "test-ps", "vpc-0aaaaaaaaaaaaaaaa") }

  def aws_location(name)
    Location.create(name:, provider: "aws", display_name: "aws-#{name}", ui_name: "aws-#{name}", visible: true).tap {
      LocationAz.create(location_id: it.id, az: "a", zone_id: "#{name}-az1")
    }
  end

  def aws_subnet(location, name, vpc_id, project_id: project.id)
    Prog::Vnet::SubnetNexus.assemble(project_id, name:, location_id: location.id).subject.tap {
      it.private_subnet_aws_resource.update(vpc_id:)
    }
  end

  def assemble(peer_vpc_id, private_subnet: ps)
    described_class.assemble(private_subnet, peer_account_id: "111122223333", peer_vpc_id:, aws: {peer_region: "us-east-1"})
  end

  def peering_rows
    [VpcPeering.count, VpcPeeringAwsResource.count, Strand.where(prog: "Vnet::Aws::VpcPeeringNexus").count]
  end

  describe ".assemble" do
    it "creates the peering, its AWS row and a strand at start, and returns the strand" do
      st = assemble("vpc-0bbbbbbbbbbbbbbbb")
      expect(st).to be_a(Strand)
      expect(st).to have_attributes(prog: "Vnet::Aws::VpcPeeringNexus", label: "start")
      vp = VpcPeering[st.id]
      expect(vp).to have_attributes(private_subnet_id: ps.id, peer_account_id: "111122223333", peer_vpc_id: "vpc-0bbbbbbbbbbbbbbbb", state: "creating", state_message: nil, peer_cidrs: [])
      expect(vp.vpc_peering_aws_resource).to have_attributes(peer_region: "us-east-1", peering_connection_id: nil, requester_account_id: nil, expires_at: nil)
    end

    it "refuses a private subnet with destroy set" do
      ps.incr_destroy
      expect { assemble("vpc-0bbbbbbbbbbbbbbbb") }.to raise_error(CloverError, "Private subnet 'test-ps' is being deleted")
        .and not_change { peering_rows }
    end

    it "refuses a private subnet that is being destroyed" do
      ps.incr_destroying
      expect { assemble("vpc-0bbbbbbbbbbbbbbbb") }.to raise_error(CloverError, "Private subnet 'test-ps' is being deleted")
        .and not_change { peering_rows }
    end

    it "refuses a second peering with the same peer VPC" do
      assemble("vpc-0bbbbbbbbbbbbbbbb")
      expect { assemble("vpc-0bbbbbbbbbbbbbbbb") }.to raise_error(Validation::ValidationFailed) { |ex|
        expect(ex.details).to eq(peer_vpc_id: "This private subnet already has a VPC peering with vpc-0bbbbbbbbbbbbbbbb. Delete it first. If you just deleted it, wait until it disappears.")
      }.and not_change { peering_rows }
    end

    it "refuses the private subnet's own VPC and any other Ubicloud VPC" do
      other_ps = aws_subnet(location, "other-ps", "vpc-0cccccccccccccccc", project_id: Project.create(name: "other-prj").id)
      ps
      ["vpc-0aaaaaaaaaaaaaaaa", other_ps.private_subnet_aws_resource.vpc_id].each do |vpc_id|
        expect { assemble(vpc_id) }.to raise_error(Validation::ValidationFailed) { |ex|
          expect(ex.details).to eq(peer_vpc_id: "#{vpc_id} is the VPC of a Ubicloud private subnet, and peering two Ubicloud VPCs is not supported. Enter the ID of a VPC you manage outside Ubicloud.")
        }.and not_change { peering_rows }
      end
    end

    it "refuses an 11th peering on a private subnet" do
      10.times { VpcPeering.create(private_subnet_id: ps.id, peer_account_id: "111122223333", peer_vpc_id: "vpc-0#{it}aaaaaaaaaaaaaaa", state: "active") }
      expect { assemble("vpc-0bbbbbbbbbbbbbbbb") }.to raise_error(CloverError, "Private subnet 'test-ps' already has 10 VPC peerings, the maximum. Delete one first. If you just deleted one, wait until it disappears.")
        .and not_change { peering_rows }
    end

    it "refuses a 6th pending request in a project and location, counting only creating and waiting_for_peer" do
      peerings = Array.new(5) { assemble("vpc-0#{it}aaaaaaaaaaaaaaa").subject }
      peerings.first.update(state: "waiting_for_peer")
      expect { assemble("vpc-0bbbbbbbbbbbbbbbb") }.to raise_error(CloverError, "This project already has 5 VPC peering requests waiting to be accepted in aws-us-west-2. Accept or delete one first. If you just deleted one, wait until it disappears.")
        .and not_change { peering_rows }

      peerings[1].update(state: "active")
      peerings[2].update(state: "failed", state_message: "The peering request was rejected in AWS account 111122223333. Delete this peering and create it again.")
      expect { assemble("vpc-0bbbbbbbbbbbbbbbb") }.to change { VpcPeering.where(state: "creating").count }.from(2).to(3)
    end

    it "does not count pending requests of other locations or other projects" do
      other_location_ps = aws_subnet(aws_location("us-east-1"), "east-ps", "vpc-0dddddddddddddddd")
      other_project_ps = aws_subnet(location, "other-ps", "vpc-0eeeeeeeeeeeeeeee", project_id: Project.create(name: "other-prj").id)
      5.times do
        assemble("vpc-0#{it}aaaaaaaaaaaaaaa", private_subnet: other_location_ps)
        assemble("vpc-0#{it}aaaaaaaaaaaaaaa", private_subnet: other_project_ps)
      end
      expect { assemble("vpc-0bbbbbbbbbbbbbbbb") }.to change { ps.vpc_peerings_dataset.count }.from(0).to(1)
    end

    def pending_in_other_projects(location, count)
      count.times do |i|
        other_ps = aws_subnet(location, "prj#{i}-ps", "vpc-#{i.to_s(16).rjust(17, "f")}", project_id: Project.create(name: "prj#{i}").id)
        VpcPeering.create(private_subnet_id: other_ps.id, peer_account_id: "111122223333", peer_vpc_id: "vpc-0bbbbbbbbbbbbbbbb", state: (i.even? ? "creating" : "waiting_for_peer"))
      end
    end

    it "refuses a 21st pending request in a managed location across projects, under the location row lock" do
      pending_in_other_projects(location, 20)
      expect(ps.location).to receive(:lock!).with(:no_key_update).and_call_original
      expect(Clog).to receive(:emit).with("VPC peering location ceiling reached", {vpc_peering_location_ceiling: {location: location.ubid, project: project.ubid}}).and_call_original
      expect { assemble("vpc-0bbbbbbbbbbbbbbbb") }.to raise_error(CloverError, "Ubicloud has reached its limit of VPC peering requests waiting to be accepted in aws-us-west-2. Try again later, or contact support@ubicloud.com.")
        .and not_change { peering_rows }
    end

    it "ignores settled peerings and other locations for the location ceiling" do
      pending_in_other_projects(location, 19)
      pending_in_other_projects(aws_location("us-east-1"), 1)
      VpcPeering.create(private_subnet_id: ps.id, peer_account_id: "111122223333", peer_vpc_id: "vpc-0cccccccccccccccc", state: "active")
      expect { assemble("vpc-0bbbbbbbbbbbbbbbb") }.to change { ps.vpc_peerings_dataset.count }.from(1).to(2)
    end

    it "does not apply the location ceiling to a BYOC location, whose quota is the customer's" do
      location.update(byoc: true, project_id: project.id)
      pending_in_other_projects(location, 20)
      expect(ps.location).not_to receive(:lock!)
      expect { assemble("vpc-0bbbbbbbbbbbbbbbb") }.to change { ps.vpc_peerings_dataset.count }.from(0).to(1)
    end

    describe "with peerings committed while it waits for the project lock" do
      def commit_before_project_lock(&)
        expect(ps.project).to receive(:lock!).with(:no_key_update).and_wrap_original do |original, *args|
          yield
          original.call(*args)
        end
      end

      it "refuses a second peering with the same peer VPC" do
        commit_before_project_lock { VpcPeering.create(private_subnet_id: ps.id, peer_account_id: "111122223333", peer_vpc_id: "vpc-0bbbbbbbbbbbbbbbb") }
        expect { assemble("vpc-0bbbbbbbbbbbbbbbb") }.to raise_error(Validation::ValidationFailed) { |ex|
          expect(ex.details).to eq(peer_vpc_id: "This private subnet already has a VPC peering with vpc-0bbbbbbbbbbbbbbbb. Delete it first. If you just deleted it, wait until it disappears.")
        }
      end

      it "refuses an 11th peering on a private subnet" do
        commit_before_project_lock { 10.times { VpcPeering.create(private_subnet_id: ps.id, peer_account_id: "111122223333", peer_vpc_id: "vpc-0#{it}aaaaaaaaaaaaaaa", state: "active") } }
        expect { assemble("vpc-0bbbbbbbbbbbbbbbb") }.to raise_error(CloverError, "Private subnet 'test-ps' already has 10 VPC peerings, the maximum. Delete one first. If you just deleted one, wait until it disappears.")
      end

      it "refuses a 6th pending request from another private subnet of the project" do
        other_ps = aws_subnet(location, "other-ps", "vpc-0cccccccccccccccc")
        commit_before_project_lock { 5.times { VpcPeering.create(private_subnet_id: other_ps.id, peer_account_id: "111122223333", peer_vpc_id: "vpc-0#{it}aaaaaaaaaaaaaaa") } }
        expect { assemble("vpc-0bbbbbbbbbbbbbbbb") }.to raise_error(CloverError, "This project already has 5 VPC peering requests waiting to be accepted in aws-us-west-2. Accept or delete one first. If you just deleted one, wait until it disappears.")
      end

      it "refuses a 21st pending request another project committed while it waited for the location lock" do
        expect(ps.location).to receive(:lock!).with(:no_key_update).and_wrap_original do |original, *args|
          pending_in_other_projects(location, 20)
          original.call(*args)
        end
        expect { assemble("vpc-0bbbbbbbbbbbbbbbb") }.to raise_error(CloverError, "Ubicloud has reached its limit of VPC peering requests waiting to be accepted in aws-us-west-2. Try again later, or contact support@ubicloud.com.")
      end
    end

    it "refuses a location of another provider and rolls back the peering" do
      metal_ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "metal-ps").subject
      expect { assemble("vpc-0bbbbbbbbbbbbbbbb", private_subnet: metal_ps) }.to raise_error(RuntimeError, "VPC peering is not supported in hetzner locations")
        .and not_change { peering_rows }
    end
  end

  describe ".assemble in a GCP location" do
    let(:location) { Location[name: "gcp-us-central1"] }
    let(:ps) { gcp_subnet("test-ps") }

    before { gcp_credential(location, "ubicloud-test") }

    def gcp_credential(location, project_id)
      LocationCredentialGcp.create_with_id(location, project_id:, service_account_email: "test@#{project_id}.iam.gserviceaccount.com", credentials_json: "{}")
    end

    def gcp_subnet(name, location: self.location, project_id: project.id, dedicated: true, is_management: false)
      Prog::Vnet::SubnetNexus.assemble(project_id, name:, location_id: location.id).subject.tap {
        Prog::Vnet::Gcp::VpcNexus.assemble(project_id, location.id, dedicated_for_subnet_id: (it.id if dedicated), is_management:).subject.add_private_subnet(it)
      }
    end

    def gcp_assemble(network, peer_project: "customer-project", private_subnet: ps)
      described_class.assemble(private_subnet, peer_account_id: peer_project, peer_vpc_id: "projects/#{peer_project}/global/networks/#{network}")
    end

    def gcp_peering_rows
      [VpcPeering.count, VpcPeeringGcpResource.count, Strand.where(prog: "Vnet::Gcp::VpcPeeringNexus").count]
    end

    it "creates the peering, its GCP row named after it and a strand at start, and returns the strand" do
      st = gcp_assemble("customer-vpc")
      expect(st).to have_attributes(prog: "Vnet::Gcp::VpcPeeringNexus", label: "start")
      vp = VpcPeering[st.id]
      expect(vp).to have_attributes(private_subnet_id: ps.id, peer_account_id: "customer-project", peer_vpc_id: "projects/customer-project/global/networks/customer-vpc", state: "creating", state_message: nil, peer_cidrs: [])
      expect(vp.vpc_peering_gcp_resource.peering_name).to eq "ubicloud-#{vp.ubid}"
    end

    it "refuses a private subnet without a VPC network of its own" do
      subnets = [
        gcp_subnet("shared-ps", dedicated: false),
        gcp_subnet("mgmt-ps", is_management: true),
        Prog::Vnet::SubnetNexus.assemble(project.id, name: "new-ps", location_id: location.id).subject,
      ]
      subnets.each do |subnet|
        expect { gcp_assemble("customer-vpc", private_subnet: subnet) }.to raise_error(CloverError, "Private subnet '#{subnet.name}' does not have its own VPC network, so it cannot be peered.")
          .and not_change { gcp_peering_rows }
      end
    end

    it "refuses a network path outside the peer project, and a bare network name" do
      %w[projects/other-project/global/networks/customer-vpc customer-vpc].each do |peer_vpc_id|
        expect { described_class.assemble(ps, peer_account_id: "customer-project", peer_vpc_id:) }.to raise_error(Validation::ValidationFailed) { |ex|
          expect(ex.details).to eq(peer_vpc_id: "#{peer_vpc_id} is not a VPC network in GCP project customer-project.")
        }.and not_change { gcp_peering_rows }
      end
    end

    it "refuses the GCP project of any Ubicloud-managed location" do
      gcp_credential(Location[name: "gcp-us-east4"], "ubicloud-other")
      %w[ubicloud-test ubicloud-other].each do |peer_project|
        expect { gcp_assemble("default", peer_project:) }.to raise_error(Validation::ValidationFailed) { |ex|
          expect(ex.details).to eq(peer_account_id: "#{peer_project} is Ubicloud's GCP project. Enter the ID of the GCP project that owns your VPC network.")
        }.and not_change { gcp_peering_rows }
      end
    end

    it "allows the location's own GCP project when a project owns the location" do
      owned = Location.create(name: "gcp-us-west1", provider: "gcp", project_id: project.id, display_name: "gcp-us-west1", ui_name: "gcp-us-west1", visible: true)
      gcp_credential(owned, "owned-project")
      owned_ps = gcp_subnet("owned-ps", location: owned)
      expect { gcp_assemble("customer-vpc", peer_project: "owned-project", private_subnet: owned_ps) }.to change { owned_ps.vpc_peerings_dataset.count }.from(0).to(1)
    end

    it "refuses a Ubicloud VPC network in any location backed by the peer project, and allows other networks" do
      other_project = Project.create(name: "other-prj")
      other_location = Location.create(name: "gcp-us-east4", provider: "gcp", project_id: other_project.id, display_name: "gcp-us-east4", ui_name: "gcp-us-east4", visible: true)
      gcp_credential(other_location, "byoc-project")
      vpc_name = Prog::Vnet::Gcp::VpcNexus.assemble(other_project.id, other_location.id).subject.name
      expect { gcp_assemble(vpc_name, peer_project: "byoc-project") }.to raise_error(Validation::ValidationFailed) { |ex|
        expect(ex.details).to eq(peer_vpc_id: "projects/byoc-project/global/networks/#{vpc_name} is a Ubicloud VPC network. Enter a VPC network in your own GCP project.")
      }.and not_change { gcp_peering_rows }

      expect {
        gcp_assemble("customer-vpc", peer_project: "byoc-project")
        gcp_assemble(vpc_name)
      }.to change { ps.vpc_peerings_dataset.count }.from(0).to(2)
    end

    it "applies no location ceiling" do
      other_ps = gcp_subnet("other-ps", project_id: Project.create(name: "other-prj").id)
      20.times { VpcPeering.create(private_subnet_id: other_ps.id, peer_account_id: "customer-project", peer_vpc_id: "projects/customer-project/global/networks/vpc-#{it}", state: "waiting_for_peer") }
      expect { gcp_assemble("customer-vpc") }.to change { ps.vpc_peerings_dataset.count }.from(0).to(1)
    end

    it "refuses a 6th peering that is not connected in a project and location, counting one whose customer side went missing" do
      peerings = Array.new(5) { gcp_assemble("vpc-#{it}").subject }
      peerings.first.update(state: "waiting_for_peer", state_message: "Your side of the peering in project customer-project is missing or inactive, so traffic does not flow.")
      expect { gcp_assemble("customer-vpc") }.to raise_error(CloverError, "This project already has 5 VPC peerings that are not connected in us-central1. Create your side of one, or delete one first. If you just deleted one, wait until it disappears.")
        .and not_change { gcp_peering_rows }

      peerings[1].update(state: "active")
      expect { gcp_assemble("customer-vpc") }.to change { ps.vpc_peerings_dataset.count }.from(5).to(6)
    end
  end
end
