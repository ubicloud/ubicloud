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
          expect(ex.details).to eq(peer_vpc_id: "#{vpc_id} is a Ubicloud VPC. Enter the ID of a VPC in your own AWS account.")
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
end
