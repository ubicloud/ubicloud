# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "private subnet vpc peering in GCP" do
  let(:user) { create_account }

  let(:project) { user.create_project_with_default_policy("project-1") }

  let(:location) { Location[name: "gcp-us-central1"] }

  let(:ps) { gcp_subnet("test-ps") }

  let(:vpc_name) { ps.gcp_vpc.name }

  let(:tab_path) { "#{project.path}#{ps.path}/vpc-peering" }

  let(:vp) { Prog::Vnet::VpcPeeringNexus.assemble(ps, peer_account_id: "customer-project", peer_vpc_id: "projects/customer-project/global/networks/customer-vpc").subject }

  let(:card) { "#vpc-peering-#{vp.ubid}" }

  let(:command) {
    "gcloud compute networks peerings create ubicloud-#{vp.ubid} --project=customer-project --network=customer-vpc " \
      "--peer-project=ubicloud-test --peer-network=#{vpc_name} --stack-type=IPV4_ONLY --no-import-custom-routes " \
      "--no-export-custom-routes --no-import-subnet-routes-with-public-ip --no-export-subnet-routes-with-public-ip"
  }

  before do
    LocationCredentialGcp.create_with_id(location, project_id: "ubicloud-test", service_account_email: "test@ubicloud-test.iam.gserviceaccount.com", credentials_json: "{}")
    allow(Config).to receive(:vpc_peering_enabled).and_return(true)
    project.set_ff_vpc_peering_gcp(true)
    login(user.email)
  end

  def gcp_subnet(name, dedicated: true)
    Prog::Vnet::SubnetNexus.assemble(project.id, name:, location_id: location.id).subject.tap {
      Prog::Vnet::Gcp::VpcNexus.assemble(project.id, location.id, dedicated_for_subnet_id: (it.id if dedicated)).subject.add_private_subnet(it)
    }
  end

  def submenu_links
    page.all("#private-subnet-submenu a").map(&:text)
  end

  def fill_in_peering(project_id: "customer-project", network: "customer-vpc")
    fill_in "GCP project ID", with: project_id
    fill_in "VPC network name", with: network
    click_button "Add peering"
  end

  it "shows the tab only for a subnet with its own VPC network while VPC peering is enabled for the project" do
    project.set_ff_vpc_peering_gcp(false)
    visit "#{project.path}#{ps.path}/overview"
    expect(submenu_links).to eq ["Overview", "Virtual Machines", "Networking", "Settings"]

    visit tab_path
    expect(page.status_code).to eq(404)

    shared_ps = gcp_subnet("shared-ps", dedicated: false)
    project.set_ff_vpc_peering_gcp(true)
    visit "#{project.path}#{shared_ps.path}/overview"
    expect(submenu_links).to eq ["Overview", "Virtual Machines", "Networking", "Settings"]

    visit "#{project.path}#{ps.path}/overview"
    expect(submenu_links).to eq ["Overview", "Virtual Machines", "Networking", "VPC Peering", "Settings"]

    within("#private-subnet-submenu") { click_link "VPC Peering" }
    expect(page.title).to eq("Ubicloud - test-ps")
    expect(page).to have_content "Ubicloud project ubicloud-test Ubicloud VPC network #{vpc_name} CIDR #{ps.net4}", normalize_ws: true
    expect(page).to have_content "No subnet range of your network may overlap #{ps.net4}, the imported subnet routes of this subnet's other peerings"
    expect(page).to have_content "GCP exchanges only private IPv4 subnet routes: no custom routes, no IPv6 and no transit through other peerings."
    expect(page).to have_content "Only private subnets with their own VPC network can be peered, and each one needs its own peering, so this peering does not reach your other private subnets or PostgreSQL databases."
    expect(page).to have_content "Connections can be opened only from your network into this subnet."
    expect(page).to have_content "No VPC peerings yet."
    expect(page).to have_field("GCP project ID")
  end

  it "shows a peering while Ubicloud adds its side" do
    vp
    visit tab_path
    within(card) do
      expect(page).to have_content "customer-vpc creating"
      expect(page).to have_content "Project customer-project"
      expect(page).to have_content "Adding Ubicloud's side of the peering..."
    end

    vp.update(state_message: "Ubicloud could not add its side of the peering yet and retries every 5 minutes. GCP said: Required 'compute.networks.addPeering' permission")
    page.refresh
    expect(page.find(card)).to have_content "Ubicloud could not add its side of the peering yet and retries every 5 minutes."
    expect(page.find(card)).to have_no_content "Adding Ubicloud's side of the peering..."
  end

  it "shows the customer how to create their side of a peering that waits for it" do
    vp.update(state: "waiting_for_peer")
    visit tab_path

    within(card) do
      expect(page).to have_content "customer-vpc waiting for peer"
      expect(page).to have_content "Ubicloud's side of the peering, ubicloud-#{vp.ubid}, is ready. Traffic flows as soon as you create the matching side in project customer-project."
      expect(page.find(".copyable-content")["data-content"]).to eq command
      expect(page).to have_content "You need compute.networks.addPeering on network customer-vpc (the Compute Network Admin role has it), and no access to Ubicloud's project."
      expect(page).to have_content "2. Allow the traffic. GCP's implied rules allow all egress from your network"
      expect(page).to have_content "allow TCP to #{ps.net4} on the ports you use (5432 and 6432 for PostgreSQL)."
      expect(page).to have_content "3. Connect over the peering. Use private IPv4 addresses"
      expect(page).to have_content "Ubicloud checks for your side every minute for the first hour, then every 5 minutes."
      expect(page).to have_no_css ".bg-yellow-50"
    end

    vp.update(state_message: "Your side of the peering in project customer-project is missing or inactive, so traffic does not flow.")
    page.refresh
    expect(page.find("#{card} .bg-yellow-50").text).to eq "Your side of the peering in project customer-project is missing or inactive, so traffic does not flow."
    expect(page.find("#{card} .copyable-content")["data-content"]).to eq command
  end

  it "shows the imported subnet routes of an active peering" do
    vp.update(state: "active", peer_cidrs: Sequel.pg_array(%w[10.200.0.0/20 10.201.0.0/20], :cidr))
    visit tab_path

    within(card) do
      expect(page).to have_content "customer-vpc active"
      expect(page).to have_content "Imported subnet routes 10.200.0.0/20, 10.201.0.0/20", normalize_ws: true
      expect(page).to have_content "Your side of the setup"
      expect(page.find("details .copyable-content", visible: false)["data-content"]).to eq command
      expect(page).to have_no_content "is ready"
    end

    vp.update(peer_cidrs: Sequel.pg_array([], :cidr))
    page.refresh
    expect(page.find(card)).to have_content "Imported subnet routes None yet", normalize_ws: true
  end

  it "shows why a peering failed, escaped" do
    vp.update(state: "failed", state_message: '<strong id="peering-error">GCP refused the peering.</strong>')
    visit tab_path

    expect(page.find("#{card} .bg-red-50").text).to eq '<strong id="peering-error">GCP refused the peering.</strong>'
    expect(page).to have_no_css "strong#peering-error"
  end

  it "adds a peering from the form" do
    visit tab_path
    fill_in_peering(project_id: "Customer-Project")

    expect(page).to have_flash_notice("Ubicloud is adding its side of the peering. Then create your side in GCP project customer-project with the command that appears below.")
    expect(page.title).to eq("Ubicloud - test-ps")
    expect(ps.vpc_peerings.map { [it.peer_account_id, it.peer_vpc_id] }).to eq [["customer-project", "projects/customer-project/global/networks/customer-vpc"]]
    expect(page).to have_content "customer-vpc creating"
  end

  it "keeps the input and shows both field errors when the input is invalid" do
    visit tab_path
    fill_in_peering(project_id: "123456789012", network: "bad;network")

    expect(page).to have_flash_error("Validation failed for following fields: peer_account_id, peer_vpc_id")
    expect(page.title).to eq("Ubicloud - test-ps")
    expect(page.find_by_id("peer_account_id-error").text).to start_with "GCP project ID must be 6 to 30 lowercase letters"
    expect(page.find_by_id("peer_vpc_id-error").text).to start_with "VPC network name must be 1 to 63 lowercase letters"
    expect(page).to have_field("GCP project ID", with: "123456789012")
    expect(ps.vpc_peerings_dataset.count).to eq 0
  end

  it "shows a refused project under its field" do
    visit tab_path
    fill_in_peering(project_id: "ubicloud-test")

    expect(page).to have_flash_error("Validation failed for following fields: peer_account_id")
    expect(page.find_by_id("peer_account_id-error").text).to eq "ubicloud-test is Ubicloud's GCP project. Enter the ID of the GCP project that owns your VPC network."
    expect(ps.vpc_peerings_dataset.count).to eq 0
  end

  it "flashes a refusal from the business rules" do
    other_ps = gcp_subnet("other-ps")
    visit tab_path
    5.times { Prog::Vnet::VpcPeeringNexus.assemble(other_ps, peer_account_id: "customer-project", peer_vpc_id: "projects/customer-project/global/networks/vpc-#{it}") }
    fill_in_peering

    expect(page).to have_flash_error("This project already has 5 VPC peerings that are not connected in us-central1. Create your side of one, or delete one first. If you just deleted one, wait until it disappears.")
    expect(ps.vpc_peerings_dataset.count).to eq 0
  end

  it "hides the form and delete buttons without PrivateSubnet:edit" do
    vp
    AccessControlEntry.dataset.destroy
    AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["PrivateSubnet:view"])
    visit tab_path

    expect(page).to have_content "customer-vpc creating"
    expect(page).to have_no_css ".delete-btn"
    expect(page).to have_no_button "Add peering"
  end

  it "deletes a peering, reminding the customer to delete their side" do
    vp
    visit tab_path
    expect(page.find("#{card} .delete-btn")["data-confirmation-message"]).to eq "Are you sure you want to delete the VPC peering with network customer-vpc in project customer-project? Traffic over it stops at once. Afterwards, delete your side of the peering in project customer-project."
    within(card) { click_button "Delete" }

    expect(page).to have_flash_notice("VPC peering with projects/customer-project/global/networks/customer-vpc is being deleted")
    expect(vp.destroy_set?(cached: false)).to be true
    within(card) do
      expect(page).to have_content "customer-vpc deleting"
      expect(page).to have_content "Removing Ubicloud's side of the peering..."
      expect(page).to have_no_css ".delete-btn"
    end
  end
end
