# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin do
  def object_data
    page.all(".object-table tbody tr").map { it.all("td").map(&:text) }.to_h.transform_keys(&:to_sym).except(:created_at)
  end

  def page_data
    page.all(".page-table tbody tr").map do
      tds = it.all("td").map(&:text)
      tds.delete_at(-3)
      tds
    end
  end

  before do
    admin_account_setup_and_login
  end

  let(:vm_pool) do
    vp = VmPool.create(
      size: 3,
      vm_size: "standard-2",
      boot_image: "img",
      location_id: Location::HETZNER_FSN1_ID,
      storage_size_gib: 86
    )
    Strand.create(prog: "Vm::VmPool", label: "create_new_vm") { it.id = vp.id }
    vp
  end

  it "allows searching by ubid and navigating to related objects" do
    expect(page.title).to eq "Ubicloud Admin"

    account = create_account
    fill_in "UBID", with: account.ubid
    click_button "Show Object"
    expect(page.title).to eq "Ubicloud Admin - Account #{account.ubid}"
    expect(object_data).to eq(email: "user@example.com", name: "", status_id: "2", suspended_at: "")

    project = account.projects.first
    click_link project.name
    expect(page.title).to eq "Ubicloud Admin - Project #{project.ubid}"
    expect(object_data).to eq(billable: "true", billing_info_id: "", credit: "0.0", discount: "0", feature_flags: "{}", name: "Default", reputation: "new", visible: "true")

    subject_tag = project.subject_tags.first
    click_link subject_tag.name
    expect(page.title).to eq "Ubicloud Admin - SubjectTag #{subject_tag.ubid}"
    expect(object_data).to eq(name: "Admin", project_id: "Default")

    # Column Link
    click_link project.name
    expect(page.title).to eq "Ubicloud Admin - Project #{project.ubid}"
  end

  it "allows browsing by class" do
    account = create_account
    AccountIdentity.create(account_id: account.id, provider: "github", uid: "789")
    project = account.projects.first
    page.refresh
    click_link "Project"
    click_link project.name
    expect(page.title).to eq "Ubicloud Admin - Project #{project.ubid}"

    click_link account.email
    expect(page.title).to eq "Ubicloud Admin - Account #{account.ubid}"
  end

  it "allows browsing by class when using Autoforme" do
    project = Project.create(name: "Default")
    vm = Prog::Vm::Nexus.assemble("dummy key", project.id, name: "my-vm").subject
    click_link "Vm"
    expect(page.title).to eq "Ubicloud Admin - Vm - Browse"
    expect(page.all("#autoforme_content td").map(&:text)).to eq ["my-vm", "creating", "", "hetzner-fsn1", "x64", "ubuntu-jammy", "standard", "2", vm.created_at.to_s]

    click_link vm.name
    expect(page.title).to eq "Ubicloud Admin - Vm #{vm.ubid}"
    path = page.current_path

    firewall = vm.firewalls.first
    click_link firewall.name
    expect(page.title).to eq "Ubicloud Admin - Firewall #{firewall.ubid}"

    visit path
    within(".associations") { click_link project.name }
    expect(page.title).to eq "Ubicloud Admin - Project #{project.ubid}"

    visit path
    within(".associations") { click_link "hetzner-fsn1" }
    expect(page.title).to eq "Ubicloud Admin - Location #{Location::HETZNER_FSN1_UBID}"
  end

  it "allows searching by class when using Autoforme" do
    project = Project.create(name: "Default")
    firewall = Firewall.create(name: "fw", project_id: project.id, location_id: Location::HETZNER_FSN1_ID)
    click_link "Firewall"
    click_link "Search"
    expect(page.title).to eq "Ubicloud Admin - Firewall - Search"

    click_button "Search"
    expect(page.all("#autoforme_content td").map(&:text)).to eq ["fw", "Default", "hetzner-fsn1", "Default firewall"]

    click_link "Search"
    fill_in "Name", with: "fw2"
    click_button "Search"
    expect(page.all("#autoforme_content td").map(&:text)).to eq []

    click_link "Search"
    fill_in "Name", with: "fw"
    click_button "Search"
    expect(page.all("#autoforme_content td").map(&:text)).to eq ["fw", "Default", "hetzner-fsn1", "Default firewall"]

    path = page.current_url
    click_link firewall.name
    expect(page.title).to eq "Ubicloud Admin - Firewall #{firewall.ubid}"

    visit path
    click_link project.name
    expect(page.title).to eq "Ubicloud Admin - Project #{project.ubid}"

    visit path
    click_link "hetzner-fsn1"
    expect(page.title).to eq "Ubicloud Admin - Location #{Location::HETZNER_FSN1_UBID}"

    sshable = Sshable.create_with_id(VmHost.generate_uuid, host: "1.1.0.0")
    vmh = VmHost.create_with_id(sshable.id, location_id: Location::HETZNER_FSN1_ID, family: "standard")
    click_link "Ubicloud Admin"
    click_link "VmHost"
    click_link "Search"

    select "standard", from: "Family"
    fill_in "Sshable", with: "1.0"
    click_button "Search"
    expect(page.all("#autoforme_content td").map(&:text)).to eq [vmh.ubid, "1.1.0.0", "unprepared", "", "hetzner-fsn1", "", "standard", "", "0"]

    vm = Vm.create(unix_user: "ubi", public_key: "k y", name: "vm1", location_id: Location::HETZNER_FSN1_ID, boot_image: "github-ubuntu-2204", family: "standard", arch: "x64", cores: 2, vcpus: 2, memory_gib: 8, project_id: project.id)
    click_link "Ubicloud Admin"
    click_link "Vm"
    click_link "Search"

    select "x64", from: "Arch"
    fill_in "Created at", with: vm.created_at.strftime("%Y-%m")
    click_button "Search"
    expect(page.all("#autoforme_content td").map(&:text)).to eq ["vm1", "creating", "", "hetzner-fsn1", "x64", "github-ubuntu-2204", "standard", "2", vm.created_at.to_s]

    GithubInstallation.create(name: "ins1", installation_id: 1, type: "Organization", allocator_preferences: {family_filter: nil})
    ins2 = GithubInstallation.create(name: "ins2", installation_id: 2, type: "Organization", allocator_preferences: {"family_filter" => ["standard", "premium"]})
    ins3 = GithubInstallation.create(name: "ins3", installation_id: 3, type: "User", allocator_preferences: {"family_filter" => ["standard"]})
    click_link "Ubicloud Admin"
    click_link "GithubInstallation"
    click_link "Search"
    path = page.current_path
    select "True", from: "Premium enabled"
    fill_in "Allocator preferences", with: "premium"
    fill_in "Created at", with: ins2.created_at.strftime("%Y-%m")
    click_button "Search"
    expect(page.all("#autoforme_content td").map(&:text)).to eq ["ins2", "2", "Organization", "true", "true", ins2.created_at.to_s, "{\"family_filter\" => [\"standard\", \"premium\"]}"]

    visit path
    select "False", from: "Premium enabled"
    select "User", from: "Type"
    click_button "Search"
    expect(page.all("#autoforme_content td").map(&:text)).to eq ["ins3", "3", "User", "true", "false", ins3.created_at.to_s, "{\"family_filter\" => [\"standard\"]}"]

    account = create_account
    AccountIdentity.create(account_id: account.id, provider: "github", uid: "789")
    click_link "Ubicloud Admin"
    click_link "Account"
    click_link "Search"

    select "True", from: "Suspended"
    click_button "Search"
    expect(page.all("#autoforme_content td").map(&:text)).to eq []

    click_link "Search"
    fill_in "Email", with: "example"
    fill_in "Created at", with: account.created_at.strftime("%Y-%m")
    click_button "Search"
    expect(page.all("#autoforme_content td").map(&:text)).to eq ["", "user@example.com", "2", "github", account.created_at.to_s, ""]

    click_link "Search"
    select "github", from: "Providers"
    select "False", from: "Suspended"
    click_button "Search"
    expect(page.all("#autoforme_content td").map(&:text)).to eq ["", "user@example.com", "2", "github", account.created_at.to_s, ""]
  end

  it "handles basic pagination when browsing by class" do
    projects = Array.new(101) { |i| Project.create(name: "project-#{i}") }
    page.refresh
    click_link "Project"
    found_projects = page.all("#object-list a").map(&:text)

    click_link "More"
    found_projects.concat(page.all("#object-list a").map(&:text))

    expect(projects.map(&:name) - found_projects).to eq []
    project = Project.last
    click_link project.name
    expect(page.title).to eq "Ubicloud Admin - Project #{project.ubid}"
  end

  it "ignores bogus ubids when paginating" do
    project = Project.create(name: "test")
    page.refresh
    click_link "Project"
    page.visit "#{page.current_path}?after=foo"
    click_link project.name
    expect(page.title).to eq "Ubicloud Admin - Project #{project.ubid}"
  end

  it "shows semaphores set on the object, if any" do
    fill_in "UBID", with: vm_pool.ubid
    click_button "Show Object"
    expect(page.title).to eq "Ubicloud Admin - VmPool #{vm_pool.ubid}"
    expect(page).to have_no_content "Semaphores Set:"

    vm_pool.incr_destroy
    page.refresh
    expect(page).to have_content "Semaphores Set: destroy"
  end

  it "shows object's strand, if any" do
    fill_in "UBID", with: vm_pool.ubid
    click_button "Show Object"
    path = page.current_path
    expect(page.title).to eq "Ubicloud Admin - VmPool #{vm_pool.ubid}"
    expect(page).to have_content "Strand: Vm::VmPool#create_new_vm | schedule: 2"
    expect(page).to have_no_content "| try"

    vm_pool.strand.update(try: 3)
    visit path
    expect(page).to have_content "| try: 3"

    click_link "Strand"
    expect(page.title).to eq "Ubicloud Admin - Strand #{vm_pool.ubid}"

    vm_pool.strand.destroy
    visit path
    expect(page).to have_no_content "Strand"
  end

  it "converts ubids to link" do
    p = Page.create(summary: "test", tag: "a", details: {"related_resources" => [vm_pool.ubid, "cc489f465gqa5pzq04gch3162h"]})
    fill_in "UBID", with: p.ubid
    click_button "Show Object"

    expect(page.title).to eq "Ubicloud Admin - Page #{p.ubid}"

    click_link vm_pool.ubid
    expect(page.title).to eq "Ubicloud Admin - VmPool #{vm_pool.ubid}"
  end

  it "shows sshable information for object, if any" do
    vm_host = Prog::Vm::HostNexus.assemble("1.2.3.4").subject
    fill_in "UBID", with: vm_host.ubid
    click_button "Show Object"
    expect(page.title).to eq "Ubicloud Admin - VmHost #{vm_host.ubid}"
    expect(page).to have_content "SSH Command: ssh root@1.2.3.4"

    visit "/"
    fill_in "UBID", with: vm_pool.ubid
    click_button "Show Object"
    expect(page).to have_no_content "SSH Command"
  end

  it "shows active pages on index page, grouped by related host" do
    expect(page).to have_no_content "Active Pages"

    page1 = Page.create(summary: "some problem", tag: "a")
    page.refresh
    expect(page).to have_content "Active Pages"
    expect(page_data).to eq [
      ["", page1.ubid, "some problem", "{}"]
    ]
    click_link page1.ubid
    expect(page.title).to eq "Ubicloud Admin - Page #{page1.ubid}"

    page2 = Page.create(summary: "another problem", tag: "b", details: {"related_resources" => [vm_pool.ubid]})
    visit "/"
    expect(page_data).to eq [
      ["", page1.ubid, "some problem", "{}"],
      [page2.ubid, "another problem", "{\"related_resources\" => [\"#{vm_pool.ubid}\"]}"]
    ]
    click_link vm_pool.ubid
    expect(page.title).to eq "Ubicloud Admin - VmPool #{vm_pool.ubid}"

    vmh = Prog::Vm::HostNexus.assemble("1.2.3.4").subject
    pj = Project.create(name: "test")
    vm = Prog::Vm::Nexus.assemble("a a", pj.id).subject
    vm.update(vm_host_id: vmh.id)
    page3 = Page.create(summary: "third problem", tag: "c", details: {"related_resources" => [vm.ubid]})
    visit "/"
    expect(page_data).to eq [
      [vmh.ubid, page3.ubid, "third problem", "{\"related_resources\" => [\"#{vm.ubid}\"]}"],
      ["", page1.ubid, "some problem", "{}"],
      [page2.ubid, "another problem", "{\"related_resources\" => [\"#{vm_pool.ubid}\"]}"]
    ]

    click_link vmh.ubid
    expect(page.title).to eq "Ubicloud Admin - VmHost #{vmh.ubid}"

    visit "/"
    click_link vm.ubid
    expect(page.title).to eq "Ubicloud Admin - Vm #{vm.ubid}"
  end

  it "handles request for invalid ubid" do
    fill_in "UBID", with: "foo"
    click_button "Show Object"
    expect(page.title).to eq "Ubicloud Admin"
    expect(page).to have_flash_error("Invalid ubid provided")

    fill_in "UBID", with: "ts1cyaqvp5ha6j5jt8ypbyagw9"
    expect { click_button "Show Object" }.to raise_error(RuntimeError, "admin route not handled: /model/SubjectTag/ts1cyaqvp5ha6j5jt8ypbyagw9")
  end

  it "handles request for invalid model or missing object" do
    %w[/model/Foo/ts1cyaqvp5ha6j5jt8ypbyagw9
      /model/ArchivedRecord/ts1cyaqvp5ha6j5jt8ypbyagw9
      /model/SubjectTag/ts1cyaqvp5ha6j5jt8ypbyagw9].each do |path|
      expect { visit path }.to raise_error(RuntimeError, "admin route not handled: #{path}")
    end
  end

  it "raises for 404 by default in tests" do
    expect { visit "/invalid-page" }.to raise_error(RuntimeError)
  end

  it "shows 404 page if DONT_RAISE_ADMIN_ERRORS environment variable is set" do
    ENV["DONT_RAISE_ADMIN_ERRORS"] = "1"
    visit "/invalid-page"
    expect(page.title).to eq "Ubicloud Admin - File Not Found"
  ensure
    ENV.delete("DONT_RAISE_ADMIN_ERRORS")
  end

  it "raises errors by default in tests" do
    expect { visit "/error" }.to raise_error(RuntimeError)
  end

  it "shows error page for errors if DONT_RAISE_ADMIN_ERRORS environment variable is set" do
    ENV["DONT_RAISE_ADMIN_ERRORS"] = "1"
    expect(Clog).to receive(:emit).with("admin route exception").and_call_original
    visit "/error"
    expect(page.title).to eq "Ubicloud Admin - Internal Server Error"
  ensure
    ENV.delete("DONT_RAISE_ADMIN_ERRORS")
  end

  it "handles incorrect/missing CSRF tokens" do
    schedule = Time.now + 10
    st = Strand.create(prog: "Test", label: "hop_entry", schedule:)
    fill_in "UBID", with: st.ubid
    click_button "Show Object"

    find("#strand-info input[name=_csrf]", visible: false).set("")
    click_button "Schedule Strand to Run Now"
    expect(page.title).to eq "Ubicloud Admin - Invalid Security Token"
    expect(page).to have_flash_error("An invalid security token submitted with this request, please try again")
    expect(st.reload.schedule).not_to be_within(5).of(Time.now)
  end

  it "raises for 404 by default for missing action" do
    location = Location.create(name: "l1", display_name: "l1", ui_name: "l1", visible: true, provider: "aws")
    path = "/model/Location/#{location.ubid}/invalid"
    expect { visit path }.to raise_error(RuntimeError, "admin route not handled: #{path}")
  end

  it "supports scheduling strands to run immediately" do
    schedule = Time.now + 10
    st = Strand.create(prog: "Test", label: "hop_entry", schedule:)
    fill_in "UBID", with: st.ubid
    click_button "Show Object"
    expect(page.title).to eq "Ubicloud Admin - Strand #{st.ubid}"

    click_button "Schedule Strand to Run Now"
    expect(page).to have_flash_notice("Scheduled strand to run immediately")
    expect(page.title).to eq "Ubicloud Admin - Strand #{st.ubid}"
    expect(st.reload.schedule).to be_within(5).of(Time.now)
  end

  it "supports restarting Vms" do
    vm = Prog::Vm::Nexus.assemble("dummy-public key", Project.create(name: "Default").id, name: "dummy-vm-1").subject
    fill_in "UBID", with: vm.ubid
    click_button "Show Object"
    expect(page.title).to eq "Ubicloud Admin - Vm #{vm.ubid}"

    expect(vm.semaphores_dataset.select_map(:name)).to eq []
    click_link "Restart"
    click_button "Restart"
    expect(page).to have_flash_notice("Restart scheduled for Vm")
    expect(page.title).to eq "Ubicloud Admin - Vm #{vm.ubid}"
    expect(vm.semaphores_dataset.select_map(:name)).to eq ["restart"]
  end

  it "supports restarting PostgresResource" do
    project_id = Project.create(name: "Default").id
    expect(Config).to receive(:postgres_service_project_id).and_return(project_id).at_least(:once)
    pg = Prog::Postgres::PostgresResourceNexus.assemble(
      project_id:,
      location_id: Location::HETZNER_FSN1_ID,
      name: "a",
      target_vm_size: "standard-2",
      target_storage_size_gib: 64
    ).subject
    fill_in "UBID", with: pg.ubid
    click_button "Show Object"
    expect(page.title).to eq "Ubicloud Admin - PostgresResource #{pg.ubid}"

    expect(Semaphore.where(strand_id: pg.servers_dataset.select_map(:id)).select_map(:name)).to eq []
    click_link "Restart"
    click_button "Restart"
    expect(page).to have_flash_notice("Restart scheduled for PostgresResource")
    expect(page.title).to eq "Ubicloud Admin - PostgresResource #{pg.ubid}"
    expect(Semaphore.where(strand_id: pg.servers_dataset.select_map(:id)).select_map(:name)).to eq ["restart"]
  end

  it "supports moving VmHost to draining/accepting state" do
    vmh = Prog::Vm::HostNexus.assemble("127.0.0.2").subject
    fill_in "UBID", with: vmh.ubid
    click_button "Show Object"
    expect(page.title).to eq "Ubicloud Admin - VmHost #{vmh.ubid}"
    expect(vmh.allocation_state).to eq "unprepared"

    click_link "Move to Draining"
    click_button "Move to Draining"
    expect(page).to have_flash_notice("Host allocation state changed to draining")
    expect(page.title).to eq "Ubicloud Admin - VmHost #{vmh.ubid}"
    expect(vmh.reload.allocation_state).to eq "draining"

    click_link "Move to Accepting"
    click_button "Move to Accepting"
    expect(page).to have_flash_notice("Host allocation state changed to accepting")
    expect(page.title).to eq "Ubicloud Admin - VmHost #{vmh.ubid}"
    expect(vmh.reload.allocation_state).to eq "accepting"
  end

  it "supports rebooting VmHosts" do
    vmh = Prog::Vm::HostNexus.assemble("127.0.0.2").subject
    fill_in "UBID", with: vmh.ubid
    click_button "Show Object"
    expect(page.title).to eq "Ubicloud Admin - VmHost #{vmh.ubid}"

    expect(vmh.semaphores_dataset.select_map(:name)).to eq []
    click_link "Reboot"
    click_button "Reboot"
    expect(page).to have_flash_notice("Reboot scheduled for VmHost")
    expect(page.title).to eq "Ubicloud Admin - VmHost #{vmh.ubid}"
    expect(vmh.semaphores_dataset.select_map(:name)).to eq ["reboot"]
  end

  it "supports hardware reseting VmHosts" do
    vmh = Prog::Vm::HostNexus.assemble("127.0.0.2").subject
    fill_in "UBID", with: vmh.ubid
    click_button "Show Object"
    expect(page.title).to eq "Ubicloud Admin - VmHost #{vmh.ubid}"

    expect(vmh.semaphores_dataset.select_map(:name)).to eq []
    click_link "Hardware Reset"
    click_button "Hardware Reset"
    expect(page).to have_flash_notice("Hardware reset scheduled for VmHost")
    expect(page.title).to eq "Ubicloud Admin - VmHost #{vmh.ubid}"
    expect(vmh.semaphores_dataset.select_map(:name)).to eq ["hardware_reset"]
  end

  it "supports provisioning spare GitHubRunner" do
    ins = GithubInstallation.create(installation_id: 123, name: "test-installation", type: "User")
    ghr = GithubRunner.create(repository_name: "test-repo", label: "ubicloud", installation_id: ins.id)

    fill_in "UBID", with: ghr.ubid
    click_button "Show Object"
    expect(page.title).to eq "Ubicloud Admin - GithubRunner #{ghr.ubid}"

    expect(GithubRunner.count).to eq 1
    click_link "Provision Spare Runner"
    click_button "Provision Spare Runner"
    expect(page).to have_flash_notice("Spare runner provisioned")
    expect(page.title).to eq "Ubicloud Admin - GithubRunner #{ghr.ubid}"
    expect(GithubRunner.count).to eq 2
    expect(GithubRunner.select_map([:repository_name, :label, :installation_id])).to eq([["test-repo", "ubicloud", ins.id]] * 2)
  end

  it "supports suspending Accounts" do
    account = create_account(with_project: false)
    fill_in "UBID", with: account.ubid
    click_button "Show Object"
    expect(page.title).to eq "Ubicloud Admin - Account #{account.ubid}"

    expect(account.suspended_at).to be_nil
    click_link "Suspend"
    click_button "Suspend"
    expect(page).to have_flash_notice("Account suspended")
    expect(page.title).to eq "Ubicloud Admin - Account #{account.ubid}"
    expect(account.reload.suspended_at).not_to be_nil
  end

  it "supports resolving Pages" do
    p = Prog::PageNexus.assemble("XYZ has an expired deadline!", ["Deadline"], "XYZ").subject

    fill_in "UBID", with: p.ubid
    click_button "Show Object"
    expect(page.title).to eq "Ubicloud Admin - Page #{p.ubid}"

    expect(p.semaphores_dataset.select_map(:name)).to eq []
    click_link "Resolve"
    click_button "Resolve"
    expect(page).to have_flash_notice("Resolve scheduled for Page")
    expect(page.title).to eq "Ubicloud Admin - Page #{p.ubid}"
    expect(p.semaphores_dataset.select_map(:name)).to eq ["resolve"]
  end
end
