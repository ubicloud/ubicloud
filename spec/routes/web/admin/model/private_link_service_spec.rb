# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "PrivateLinkService" do
  include AdminModelSpecHelper

  before do
    # The extras view reads the AWS row, so the service needs an AWS location.
    aws_location = Location.create(name: "us-west-2", display_name: "AWS US West 2", ui_name: "AWS US West", visible: true, provider: "aws", project_id: nil)
    ps = PrivateSubnet.create(name: "test-ps", project_id: Project.create(name: "test-project").id, location_id: aws_location.id, net4: "10.0.0.0/26", net6: "fdfa::/64")
    @instance = PrivateLinkService.create(name: "test-es", project_id: ps.project_id, location_id: ps.location_id, private_subnet_id: ps.id)
    @aws = PrivateLinkServiceAwsResource.create_with_id(@instance)
    admin_account_setup_and_login
  end

  it "displays the PrivateLinkService instance page correctly" do
    click_link "PrivateLinkService"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - PrivateLinkService"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - PrivateLinkService #{@instance.ubid}"
    expect(page).to have_content "Approved Consumer Endpoints"
    expect(page).to have_content "No data available for Approved Consumer Endpoints table"
  end

  it "lists the approved consumer endpoints read-only, with readable target IPs on the AWS row" do
    aws = @aws
    aws.update(registered_target_ips: Sequel.pg_array(["172.25.1.233"], :inet))
    PrivateLinkServiceAwsAllowedEndpoint.create(private_link_service_aws_resource_id: aws.id, vpc_endpoint_id: "vpce-0123456789abcdef0", description: "analytics team")
    PrivateLinkServiceAwsAllowedEndpoint.create(private_link_service_aws_resource_id: aws.id, vpc_endpoint_id: "vpce-0123456789abcdef1")

    visit "/model/PrivateLinkService/#{@instance.ubid}"
    expect(page).to have_content "Acceptance is always required"
    cells = page.all(".private-link-service-allowed-endpoints-table td").map(&:text)
    expect(cells).to include("vpce-0123456789abcdef0", "analytics team", "vpce-0123456789abcdef1")
    expect(page.all(".private-link-service-allowed-endpoints-table input[type=submit]")).to be_empty

    # inet[] columns render as plain addresses in the AWS row's data table.
    visit "/model/PrivateLinkServiceAwsResource/#{aws.ubid}"
    expect(page.status_code).to eq 200
    expect(page.all(".object-table td").map(&:text)).to include('["172.25.1.233"]')
  end
end
