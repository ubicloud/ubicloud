# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe PrivateLinkServiceAwsAllowedEndpoint do
  let(:project) { Project.create(name: "test-prj") }

  let(:aws) do
    loc = Location.create(name: "us-west-2", provider: "aws", project_id: project.id, display_name: "us-west-2-cell-0", ui_name: "aws loc", visible: true)
    ps = PrivateSubnet.create(name: "test-ps", project_id: project.id, location_id: loc.id, net4: "10.0.0.0/26", net6: "fdfa::/64")
    pls = PrivateLinkService.create(name: "test-es", project_id: project.id, location_id: ps.location_id, private_subnet_id: ps.id)
    PrivateLinkServiceAwsResource.create_with_id(pls)
  end

  it "belongs to the AWS row, is listed by endpoint id and defaults to an empty description" do
    described_class.create(private_link_service_aws_resource_id: aws.id, vpc_endpoint_id: "vpce-b", description: "team b")
    a = described_class.create(private_link_service_aws_resource_id: aws.id, vpc_endpoint_id: "vpce-a")
    expect(a.description).to eq ""
    expect(a.private_link_service_aws_resource.id).to eq aws.id
    expect(aws.allowed_endpoints.map { [it.vpc_endpoint_id, it.description] }).to eq [["vpce-a", ""], ["vpce-b", "team b"]]
  end

  it "lists each endpoint once per service" do
    described_class.create(private_link_service_aws_resource_id: aws.id, vpc_endpoint_id: "vpce-a")
    expect { described_class.create(private_link_service_aws_resource_id: aws.id, vpc_endpoint_id: "vpce-a") }.to raise_error(Sequel::ValidationFailed, /already taken/)
  end
end
