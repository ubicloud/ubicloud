# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe PrivateLinkServiceAwsResource do
  let(:project) { Project.create(name: "test-prj") }

  let(:pls) do
    loc = Location.create(name: "us-west-2", provider: "aws", project_id: project.id, display_name: "us-west-2-cell-0", ui_name: "aws loc", visible: true)
    ps = PrivateSubnet.create(name: "test-ps", project_id: project.id, location_id: loc.id, net4: "10.0.0.0/26", net6: "fdfa::/64")
    pls = PrivateLinkService.create(name: "test-es", project_id: project.id, location_id: ps.location_id, private_subnet_id: ps.id)
    Strand.create_with_id(pls, prog: "Vnet::PrivateLinkServiceNexus", label: "wait")
    pls
  end

  let(:aws) { described_class.create_with_id(pls) }

  def approve(vpc_endpoint_id, description = "")
    PrivateLinkServiceAwsAllowedEndpoint.create(private_link_service_aws_resource_id: aws.id, vpc_endpoint_id:, description:)
  end

  it "shares its service's id and ubid, with empty provider state by default" do
    expect(aws.private_link_service.id).to eq pls.id
    expect(aws.ubid).to eq pls.ubid
    expect(pls.reload.private_link_service_aws_resource.id).to eq aws.id
    expect(aws.nlb_arn).to be_nil
    expect(aws.service_name).to be_nil
    expect(aws.supported_regions).to eq []
    expect(aws.registered_target_ips).to eq []
  end

  it "knows whether the private DNS name is verified" do
    expect(aws.private_dns_verified?).to be false
    aws.update(private_dns_verification_state: "verified")
    expect(aws.private_dns_verified?).to be true
  end

  it "is due for a private DNS check while a name is set, unverified, and not attempted in the last 30 minutes" do
    now = Time.now
    expect(aws.private_dns_verification_due?(now)).to be false

    pls.update(private_dns_name: "db.example.com")
    expect(aws.reload.private_dns_verification_due?(now)).to be true

    aws.update(private_dns_verification_attempted_at: now - 10)
    expect(aws.private_dns_verification_due?(now)).to be false

    aws.update(private_dns_verification_attempted_at: now - described_class::PRIVATE_DNS_VERIFICATION_INTERVAL - 1)
    expect(aws.private_dns_verification_due?(now)).to be true

    aws.update(private_dns_verification_state: "verified")
    expect(aws.private_dns_verification_due?(now)).to be false
  end

  it "forgets the last verification attempt" do
    aws.update(private_dns_verification_attempted_at: Time.now)
    aws.forget_private_dns_verification
    expect(aws.reload.private_dns_verification_attempted_at).to be_nil
  end

  describe "#private_dns_verification_record_name" do
    it "is nil without a private DNS name or before AWS issued a record" do
      expect(aws.private_dns_verification_record_name).to be_nil

      pls.update(private_dns_name: "db.c0.example.com")
      expect(aws.reload.private_dns_verification_record_name).to be_nil
    end

    it "places the issued name under the verified domain, a wildcard at its domain" do
      pls.update(private_dns_name: "db.c0.example.com")
      aws.update(private_dns_verification_name: "_abc123")
      expect(aws.reload.private_dns_verification_record_name).to eq "_abc123.db.c0.example.com"

      pls.update(private_dns_name: "*.c0.example.com")
      expect(aws.reload.private_dns_verification_record_name).to eq "_abc123.c0.example.com"
    end
  end

  it "stores extra supported regions without the home region and requests a reconcile" do
    aws.update_supported_regions(["us-east-1", "eu-west-1", "us-east-1", "us-west-2"])
    expect(aws.reload.supported_regions).to eq ["eu-west-1", "us-east-1"]
    expect(pls.reconcile_set?).to be true
  end

  it "takes the selectable regions from the SDK's partition data, without the global pseudo region" do
    regions = described_class.supported_regions
    expect(regions).to eq regions.sort
    expect(regions).to include("us-east-1", "eu-west-1", "ca-west-1", "ap-southeast-5")
    expect(regions).not_to include("aws-global", "us-gov-west-1", "cn-north-1")
  end

  it "replaces the approved consumer endpoints with their descriptions and asks for a connection reconcile only" do
    approve("vpce-old", "gone after the update")
    aws.update_allowed_endpoints([["vpce-b", "team b"], ["vpce-a", ""]])
    expect(aws.allowed_endpoints.map { [it.vpc_endpoint_id, it.description] }).to eq [["vpce-a", ""], ["vpce-b", "team b"]]
    expect(pls.reconcile_connections_set?).to be true
    expect(pls.reconcile_set?).to be false

    aws.update_allowed_endpoints([])
    expect(aws.allowed_endpoints).to eq []
  end

  it "renders registered target IPs readably on the admin page" do
    aws.update(registered_target_ips: Sequel.pg_array(["172.25.1.233", "172.25.2.48"], :inet))
    expect(aws.inspect_values_hash[:registered_target_ips]).to eq ["172.25.1.233", "172.25.2.48"]
  end

  it "destroys its approved endpoints with it" do
    approve("vpce-1")
    expect(aws.allowed_endpoints.count).to eq 1
    aws.destroy
    expect(PrivateLinkServiceAwsAllowedEndpoint.where(private_link_service_aws_resource_id: pls.id).count).to eq 0
  end
end
