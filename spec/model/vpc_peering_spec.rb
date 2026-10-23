# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe VpcPeering do
  subject(:vp) { described_class.create(private_subnet_id: ps.id, peer_account_id: "111122223333", peer_vpc_id: "vpc-0a1b2c3d4e5f60718") }

  let(:project) { Project.create(name: "test") }
  let(:ps) { PrivateSubnet.create(name: "ps", project_id: project.id, location_id: Location::HETZNER_FSN1_ID, net4: "10.9.0.0/16", net6: "fd1b:9793:dcef:cd0a::/64") }

  it "belongs to its private subnet, which lists its peerings oldest first" do
    expect(vp.private_subnet.id).to eq ps.id
    older = described_class.create(private_subnet_id: ps.id, peer_account_id: "111122223333", peer_vpc_id: "vpc-0b1b2c3d4e5f60718", created_at: Time.now - 60)
    expect(ps.vpc_peerings.map(&:id)).to eq [older.id, vp.id]
  end

  it "rejects a state outside the stored states" do
    expect { vp.update(state: "deleting") }.to raise_error(Sequel::ValidationFailed, "state is invalid")
  end

  it "requires a state message on a failed peering" do
    expect { vp.update(state: "failed") }.to raise_error(Sequel::ValidationFailed, "state and state_message is invalid")
    expect { vp.update(state: "failed", state_message: "The peering request was rejected.") }.to change { vp.reload.state }.from("creating").to("failed")
  end

  it "allows one peering per peer VPC on a private subnet, whatever the account" do
    expect {
      described_class.create(private_subnet_id: ps.id, peer_account_id: "444455556666", peer_vpc_id: vp.peer_vpc_id)
    }.to raise_error(Sequel::ValidationFailed, "private_subnet_id and peer_vpc_id is already taken")

    other_ps = PrivateSubnet.create(name: "other-ps", project_id: project.id, location_id: Location::HETZNER_FSN1_ID, net4: "10.10.0.0/16", net6: "fd1b:9793:dcef:cd0b::/64")
    expect {
      described_class.create(private_subnet_id: other_ps.id, peer_account_id: vp.peer_account_id, peer_vpc_id: vp.peer_vpc_id)
    }.to change { described_class.where(peer_vpc_id: vp.peer_vpc_id).count }.from(1).to(2)
  end

  it "records a peering connection only together with its requester account" do
    expect {
      VpcPeeringAwsResource.create_with_id(vp, peer_region: "us-east-1", peering_connection_id: "pcx-0123456789abcdef0")
    }.to raise_error(Sequel::ValidationFailed, "peering_connection_id and requester_account_id is invalid")

    aws = VpcPeeringAwsResource.create_with_id(vp, peer_region: "us-east-1")
    expect { aws.update(requester_account_id: "999988887777") }.to raise_error(Sequel::ValidationFailed, "peering_connection_id and requester_account_id is invalid")
    expect {
      aws.update(peering_connection_id: "pcx-0123456789abcdef0", requester_account_id: "999988887777")
    }.to change { aws.reload.peering_connection_id }.from(nil).to("pcx-0123456789abcdef0")
  end

  it "rejects one peering connection recorded on two peerings" do
    VpcPeeringAwsResource.create_with_id(vp, peer_region: "us-west-2", peering_connection_id: "pcx-0123456789abcdef0", requester_account_id: "999988887777")
    other = described_class.create(private_subnet_id: ps.id, peer_account_id: "111122223333", peer_vpc_id: "vpc-0b1b2c3d4e5f60718")
    expect {
      VpcPeeringAwsResource.create_with_id(other, peer_region: "us-west-2", peering_connection_id: "pcx-0123456789abcdef0", requester_account_id: "999988887777")
    }.to raise_error(Sequel::ValidationFailed, "peering_connection_id is already taken")
  end

  it "keeps its private subnet from being destroyed" do
    vp
    expect { ps.destroy }.to raise_error(Sequel::ForeignKeyConstraintViolation, /vpc_peering_private_subnet_id_fkey/)
  end

  it "excludes peerings with destroy or destroying set from not_deleting" do
    marked, destroying = %w[vpc-0b1b2c3d4e5f60718 vpc-0c1b2c3d4e5f60718].map {
      described_class.create(private_subnet_id: ps.id, peer_account_id: "111122223333", peer_vpc_id: it)
    }
    [vp, marked, destroying].each { Strand.create_with_id(it, prog: "Vnet::Aws::VpcPeeringNexus", label: "wait") }
    marked.incr_destroy
    destroying.incr_destroying
    expect(ps.vpc_peerings_dataset.not_deleting.select_map(:id)).to eq [vp.id]
  end

  it "shows deleting while destroy or destroying is set, and the stored state otherwise" do
    Strand.create_with_id(vp, prog: "Vnet::Aws::VpcPeeringNexus", label: "wait")
    %w[creating waiting_for_peer configuring active].each do
      vp.update(state: it)
      expect(vp.display_state).to eq it
    end
    vp.update(state: "failed", state_message: "The peering request was rejected in AWS account 111122223333.")
    expect(vp.display_state).to eq "failed"

    vp.incr_destroy
    expect(vp.reload.display_state).to eq "deleting"
    vp.decr_destroy
    vp.incr_destroying
    expect(vp.reload.display_state).to eq "deleting"
  end

  it "destroys its AWS resource and keeps a deleted record of both" do
    VpcPeeringAwsResource.create_with_id(vp, peer_region: "us-west-2")
    expect { vp.destroy }.to change { DeletedRecord.where(record_id: vp.id).select_order_map(:model_name) }.from([]).to(%w[VpcPeering VpcPeeringAwsResource])
  end
end
