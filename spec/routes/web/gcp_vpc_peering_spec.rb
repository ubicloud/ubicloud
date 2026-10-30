# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "GCP VPC peering console" do
  let(:user) { create_account }
  let(:project) { user.create_project_with_default_policy("peering-project") }
  let(:location) { Location[name: "gcp-us-central1"] }
  let(:ps) { Prog::Vnet::SubnetNexus.assemble(project.id, location_id: location.id).subject }
  let(:vpc) { Prog::Vnet::Gcp::VpcNexus.assemble(project.id, location.id, dedicated_for_subnet_id: ps.id).subject }
  let(:url) { "#{project.path}#{ps.path}/networking" }

  before do
    project.update(gcp_dedicated_subnet_vpcs: true)
    project.set_ff_vpc_peering_gcp(true)
    LocationCredentialGcp.create_with_id(location, project_id: "ubicloud-test", service_account_email: "test@ubicloud-test.iam.gserviceaccount.com", credentials_json: "{}")
    vpc.add_private_subnet(ps)
    login(user.email)
  end

  it "connects and disconnects through the existing networking page" do
    visit url
    fill_in "GCP project ID", with: "customer-project"
    fill_in "VPC network name", with: "customer-vpc"
    click_button "Connect VPC"
    expect(page).to have_flash_notice("VPC peering is being configured. Create the matching peering in your GCP project.")
    expect(page).to have_content("creating")
    command = page.find("[data-content*='gcloud compute networks peerings create']")["data-content"]
    expect(command).to include("--network=customer-vpc", "--peer-project=ubicloud-test", "--peer-network=#{vpc.name}", "--stack-type=IPV4_ONLY")
    click_button "Disconnect VPC"
    expect(page).to have_flash_notice("VPC peering is being disconnected.")
    expect(page).to have_content("deleting")
    expect(vpc.reload.peering_state).to eq("deleting")
  end

  it "displays validation errors without creating a peer" do
    visit url
    fill_in "GCP project ID", with: "bad"
    fill_in "VPC network name", with: "bad;name"
    click_button "Connect VPC"
    expect(page).to have_content("Enter a GCP project ID")
    expect(page).to have_content("Enter a VPC network name")
    expect(vpc.reload.peer_network).to be_nil
  end

  it "hides creation for shared VPCs and projects without the flag" do
    project.set_ff_vpc_peering_gcp(false)
    visit url
    expect(page).to have_no_content("VPC Peering")
    project.set_ff_vpc_peering_gcp(true)
    vpc.update(dedicated_for_subnet_id: nil)
    visit url
    expect(page).to have_no_content("VPC Peering")
  end

  it "lets viewers read status and escaped provider errors without exposing mutation controls" do
    AccessControlEntry.dataset.destroy
    AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["PrivateSubnet:view"])
    visit url
    expect(page).to have_content("VPC Peering")
    expect(page).to have_no_button("Connect VPC")
    vpc.configure_peering(peer_project_id: "customer-project", peer_network_name: "customer-vpc")
    vpc.update(peering_state: "failed", peering_state_message: '<strong id="peering-error">Provider error</strong>')
    visit url
    expect(page).to have_content("Provider error")
    expect(page).to have_no_css("strong#peering-error")
    expect(page).to have_no_button("Disconnect VPC")
  end

  it "links from PostgreSQL networking and exposes the private connection string" do
    service_project = Project.create(name: "postgres-service")
    allow(Config).to receive_messages(postgres_service_project_id: service_project.id, postgres_service_hostname_v3: "pg.example.com")
    DnsZone.create(project_id: service_project.id, name: "pg.example.com")
    pg = create_postgres_resource(project:, location_id: Location::HETZNER_FSN1_ID)
    pg.update(private_subnet_id: ps.id)
    create_postgres_server(resource: pg)
    pg.update(location_id: location.id)
    pg.strand.update(label: "wait")
    visit "#{project.path}#{pg.path}/networking"
    click_link "Manage VPC peering"
    expect(page).to have_current_path(url)
    DB[:private_subnet_gcp_vpc].where(private_subnet_id: ps.id, gcp_vpc_id: vpc.id).delete
    visit "#{project.path}#{pg.path}/connection"
    expect(page).to have_no_content("Use Private DNS?")
    vpc.add_private_subnet(ps)
    vpc.configure_peering(peer_project_id: "customer-project", peer_network_name: "customer-vpc")
    visit "#{project.path}#{pg.path}/connection"
    expect(page).to have_content("Use Private DNS?")
    expect(page.html).to include(pg.private_hostname)

    visit "#{project.path}#{pg.path}/settings"
    click_button "Add AAAA Record"
    expect(pg.dns_zone.records_dataset.where(type: "AAAA", tombstoned: false).select_map(:name)).to eq([pg.hostname + "."])
  end
end
