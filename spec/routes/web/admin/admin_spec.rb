# frozen_string_literal: true

require_relative "spec_helper"
require "stripe"

RSpec.describe CloverAdmin do
  def object_data
    page.all(".object-table tbody tr").to_h { it.all("td").map(&:text) }.transform_keys(&:to_sym).except(:created_at)
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
      storage_size_gib: 86,
    )
    Strand.create(prog: "Vm::VmPool", label: "create_new_vm") { it.id = vp.id }
    vp
  end

  it "allows searching by ubid and navigating to related objects" do
    expect(page.title).to eq "Ubicloud Admin"

    account = create_account
    fill_in "UBID, UUID, or prefix:term", with: account.ubid
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

  it "allows searching by uuid" do
    expect(page.title).to eq "Ubicloud Admin"

    account = create_account
    fill_in "UBID, UUID, or prefix:term", with: account.id
    click_button "Show Object"
    expect(page.title).to eq "Ubicloud Admin - Account #{account.ubid}"
    expect(object_data).to eq(email: "user@example.com", name: "", status_id: "2", suspended_at: "")

    fill_in "UBID, UUID, or prefix:term", with: "fed39539-ffe4-417d-9b8a-9a41ff7d4ad2"
    click_button "Show Object"
    expect(page.title).to eq "Ubicloud Admin - Search"
    expect(page).to have_flash_error(/Use prefix:term syntax to search/)
  end

  it "searches by account email with prefix and redirects for single result" do
    account = create_account

    fill_in "UBID, UUID, or prefix:term", with: "ac:user@example.com"
    click_button "Show Object"
    expect(page.title).to eq "Ubicloud Admin - Account #{account.ubid}"
  end

  it "searches by account name with prefix and redirects for single result" do
    account = create_account
    account.update(name: "UniqueTestName")

    fill_in "UBID, UUID, or prefix:term", with: "ac:UniqueTestName"
    click_button "Show Object"
    expect(page.title).to eq "Ubicloud Admin - Account #{account.ubid}"
  end

  it "searches by vm name with prefix and redirects for single result" do
    project = Project.create(name: "Default")
    vm = Prog::Vm::Nexus.assemble("dummy key", project.id, name: "unique-vm-search").subject

    fill_in "UBID, UUID, or prefix:term", with: "vm:unique-vm-search"
    click_button "Show Object"
    expect(page.title).to eq "Ubicloud Admin - Vm #{vm.ubid}"
  end

  it "searches by postgres resource name with prefix and redirects for single result" do
    project = Project.create(name: "Default")
    expect(Config).to receive(:postgres_service_project_id).and_return(project.id).at_least(:once)
    pg = Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: project.id,
      location_id: Location::HETZNER_FSN1_ID,
      name: "unique-pg-search",
      target_vm_size: "standard-2",
      target_storage_size_gib: 64,
    ).subject

    fill_in "UBID, UUID, or prefix:term", with: "pg:unique-pg-search"
    click_button "Show Object"
    expect(page.title).to eq "Ubicloud Admin - PostgresResource #{pg.ubid}"
  end

  it "searches by github installation name with prefix and redirects for single result" do
    ins = GithubInstallation.create(name: "unique-gh-install", installation_id: 999, type: "User")

    fill_in "UBID, UUID, or prefix:term", with: "g1:unique-gh-install"
    click_button "Show Object"
    expect(page).to have_current_path("/model/GithubInstallation/#{ins.ubid}")
  end

  it "searches by invoice number with prefix and redirects for single result" do
    project = Project.create(name: "Default")
    invoice = Invoice.create(
      project_id: project.id,
      invoice_number: "2512-searchtest-01",
      content: {billing_info: {country: "NL"}, cost: 1.0, subtotal: 1.0},
      status: "unpaid",
      begin_time: Time.now,
      end_time: Time.now + 30 * 24 * 60 * 60,
    )

    fill_in "UBID, UUID, or prefix:term", with: "1v:2512-searchtest-01"
    click_button "Show Object"
    expect(page.title).to eq "Ubicloud Admin - Invoice #{invoice.ubid}"
  end

  it "searches by billing info stripe_id with prefix and redirects for single result" do
    bi = BillingInfo.create(stripe_id: "cs_unique_search_test")

    fill_in "UBID, UUID, or prefix:term", with: "b1:cs_unique_search_test"
    click_button "Show Object"
    expect(page).to have_current_path("/model/BillingInfo/#{bi.ubid}")
  end

  it "shows multiple results from same model" do
    account1 = create_account("test1@example.com")
    account2 = create_account("test2@example.com")

    fill_in "UBID, UUID, or prefix:term", with: "ac:example.com"
    click_button "Show Object"
    expect(page.title).to eq "Ubicloud Admin - Search"
    expect(page).to have_css("#search-results")
    expect(page).to have_link(account1.admin_label)
    expect(page).to have_link(account2.admin_label)
  end

  it "searches with multiple comma-separated terms" do
    account1 = create_account("alice@example.com")
    account2 = create_account("bob@test.com")

    fill_in "UBID, UUID, or prefix:term", with: "ac:alice@example.com,bob@test.com"
    click_button "Show Object"
    expect(page.title).to eq "Ubicloud Admin - Search"
    expect(page).to have_link(account1.admin_label)
    expect(page).to have_link(account2.admin_label)
  end

  it "shows truncation warning when a model has more than 10 results" do
    11.times { |i| GithubInstallation.create(name: "trunctest-#{i}", installation_id: 800 + i, type: "User") }

    fill_in "UBID, UUID, or prefix:term", with: "g1:trunctest"
    click_button "Show Object"
    expect(page.title).to eq "Ubicloud Admin - Search"
    expect(page).to have_content "Results are truncated"
  end

  it "shows error for unknown search prefix" do
    fill_in "UBID, UUID, or prefix:term", with: "xx:something"
    click_button "Show Object"
    expect(page.title).to eq "Ubicloud Admin - Search"
    expect(page).to have_flash_error(/Unknown prefix: xx/)
  end

  it "shows error for search without prefix" do
    fill_in "UBID, UUID, or prefix:term", with: "no-prefix-term"
    click_button "Show Object"
    expect(page.title).to eq "Ubicloud Admin - Search"
    expect(page).to have_flash_error(/Use prefix:term syntax to search/)
  end

  it "shows no results for unmatched search term with prefix" do
    fill_in "UBID, UUID, or prefix:term", with: "vm:nonexistent-thing-xyz"
    click_button "Show Object"
    expect(page.title).to eq "Ubicloud Admin - Search"
    expect(page).to have_content "No results found"
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

  it "allows browsing all classes" do
    classes = Sequel::Model.subclasses.map { [it, it.subclasses] }.flatten.select { it < ResourceMethods::InstanceMethods }.sort_by(&:name)
    classes.each do |cls|
      visit "/model/#{cls.name}"
      expect(page.status_code).to eq 200
      expect(page.title).to eq "Ubicloud Admin - #{cls.name}"
    end
  end

  it "allows browsing by class when using Autoforme" do
    project = Project.create(name: "Default")
    vm = Prog::Vm::Nexus.assemble("dummy key", project.id, name: "my-vm").subject
    click_link "Vm"
    expect(page.title).to eq "Ubicloud Admin - Vm - Browse"
    expect(page.all("#autoforme_content td").map(&:text)).to eq ["my-vm", "creating", "Default", "", "hetzner-fsn1", "x64", "ubuntu-jammy", "standard", "2", vm.created_at.to_s]

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
    project = Project.create(name: "Test")
    firewall = Firewall.create(name: "fw", project_id: project.id, location_id: Location::HETZNER_FSN1_ID)
    click_link "Firewall"
    click_link "Search"
    expect(page.title).to eq "Ubicloud Admin - Firewall - Search"

    click_button "Search"
    expect(page.all("#autoforme_content td").map(&:text)).to eq ["fw", "Test", "hetzner-fsn1", "Default firewall"]

    click_link "Search"
    fill_in "Name", with: "fw2"
    click_button "Search"
    expect(page.all("#autoforme_content td").map(&:text)).to eq []

    click_link "Search"
    fill_in "Name", with: "fw"
    click_button "Search"
    expect(page.all("#autoforme_content td").map(&:text)).to eq ["fw", "Test", "hetzner-fsn1", "Default firewall"]

    path = page.current_url
    click_link firewall.name
    expect(page.title).to eq "Ubicloud Admin - Firewall #{firewall.ubid}"

    visit path
    click_link project.name
    expect(page.title).to eq "Ubicloud Admin - Project #{project.ubid}"

    visit path
    click_link "hetzner-fsn1"
    expect(page.title).to eq "Ubicloud Admin - Location #{Location::HETZNER_FSN1_UBID}"

    vmh = Prog::Vm::HostNexus.assemble("1.1.0.0", location_id: Location::HETZNER_FSN1_ID, family: "standard").subject
    click_link "Ubicloud Admin"
    click_link "VmHost"
    click_link "Search"

    select "standard", from: "Family"
    fill_in "Sshable", with: "1.0"
    click_button "Search"
    expect(page.all("#autoforme_content td").map(&:text)).to eq [vmh.ubid, "1.1.0.0", "unprepared", "", "hetzner-fsn1", "", "standard", "", "0"]

    vm = Prog::Vm::Nexus.assemble("k y", project.id, unix_user: "ubi", name: "vm1", location_id: Location::HETZNER_FSN1_ID, boot_image: "github-ubuntu-2204", size: "standard-2", arch: "x64").subject
    click_link "Ubicloud Admin"
    click_link "Vm"
    click_link "Search"

    select "x64", from: "Arch"
    fill_in "Project", with: project.ubid
    fill_in "Created at", with: vm.created_at.strftime("%Y-%m")
    click_button "Search"
    expect(page.all("#autoforme_content td").map(&:text)).to eq ["vm1", "creating", "Test", "", "hetzner-fsn1", "x64", "github-ubuntu-2204", "standard", "2", vm.created_at.to_s]

    GithubInstallation.create(name: "ins1", installation_id: 1, type: "Organization", allocator_preferences: {family_filter: nil})
    ins2 = GithubInstallation.create(name: "ins2", installation_id: 2, type: "Organization", allocator_preferences: {"family_filter" => ["standard", "premium"]})
    ins3 = GithubInstallation.create(name: "ins3", installation_id: 3, type: "User", allocator_preferences: {"family_filter" => ["standard"]})
    runner = Prog::Github::GithubRunnerNexus.assemble(ins2, repository_name: "ubicloud/test", label: "ubicloud").subject
    GithubRunner.create(installation_id: ins2.id, repository_name: "ubicloud/test", label: "ubicloud")
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

    click_link "Ubicloud Admin"
    click_link "GithubRunner"
    click_link "Search"

    fill_in "Repository name", with: "ubicloud"
    fill_in "Strand label", with: "start"
    fill_in "Installation", with: ins2.ubid
    fill_in "Created at", with: ins2.created_at.strftime("%Y-%m")
    click_button "Search"
    expect(page.all("#autoforme_content td").map(&:text)).to eq [runner.ubid, "ubicloud/test", "ubicloud", "start", runner.created_at.to_s]

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

    click_link "Ubicloud Admin"
    click_link "Strand"
    click_link "Search"
    fill_in "Prog", with: "Vm::Metal::Nexus"
    click_button "Search"
    expect(page.all("#autoforme_content td").map(&:text)).to eq [vm.ubid, "Vm::Metal::Nexus", "start", vm.strand.schedule.to_s, "0"]

    click_link "Ubicloud Admin"
    click_link "Project"
    click_link "Search"

    select "new", from: "Reputation"
    fill_in "Name", with: "Def"
    fill_in "Created at", with: project.created_at.strftime("%Y-%m")
    click_button "Search"
    expect(page.all("#autoforme_content td").map(&:text)).to eq ["Default", "new", "", "0.0", project.created_at.to_s]

    invoice = Invoice.create(
      project_id: project.id,
      invoice_number: "2512-f859vb27-01",
      content: {billing_info: {country: "NL"}, cost: 1.652, subtotal: 2.6530000000000005},
      begin_time: "2024-11-01 00:00:00",
      end_time: "2024-12-01 00:00:00",
    )

    click_link "Ubicloud Admin"
    click_link "Invoice"
    click_link "Search"
    fill_in "Project", with: project.ubid
    select "unpaid", from: "Status"
    click_button "Search"
    expect(page.all("#autoforme_content td").map(&:text)).to eq [invoice.invoice_number, "Test", "unpaid", "$2.65", "$1.65"]

    click_link "Search"
    fill_in "Project", with: "a" * 30
    click_button "Search"
    expect(page.all("#autoforme_content td").map(&:text)).to eq []
  end

  it "allows navigating from object to assoc table" do
    ins = GithubInstallation.create(installation_id: 123, name: "test-inst", type: "User", allocator_preferences: {})
    runner = Prog::Github::GithubRunnerNexus.assemble(ins, repository_name: "ubicloud/test", label: "ubicloud").subject

    visit "/model/GithubInstallation/#{ins.ubid}"
    expect(page.title).to eq "Ubicloud Admin - GithubInstallation #{ins.ubid}"

    within(".association", text: "runners") { click_link "(table)" }
    expect(page.title).to eq "Ubicloud Admin - GithubRunner - Search"
    expect(page.all("#autoforme_content td").map(&:text)).to eq [runner.ubid, "ubicloud/test", "ubicloud", "start", runner.created_at.to_s]

    repo = runner.repository
    visit "/model/GithubRepository/#{repo.ubid}"
    within(".association", text: "runners") { click_link "(table)" }
    expect(page.title).to eq "Ubicloud Admin - GithubRunner - Search"
    expect(page.all("#autoforme_content td").map(&:text)).to eq [runner.ubid, "ubicloud/test", "ubicloud", "start", runner.created_at.to_s]

    project = Project.create(name: "assoc-table-test")
    vm = Prog::Vm::Nexus.assemble("k y", project.id, name: "assoc-table-vm").subject

    visit "/model/Project/#{project.ubid}"
    expect(page.title).to eq "Ubicloud Admin - Project #{project.ubid}"

    within(".association", text: "vms") { click_link "(table)" }
    expect(page.title).to eq "Ubicloud Admin - Vm - Search"
    expect(page.all("#autoforme_content td").map(&:text)).to eq ["assoc-table-vm", "creating", "assoc-table-test", "", "hetzner-fsn1", "x64", "ubuntu-jammy", "standard", "2", vm.created_at.to_s]

    expect(Config).to receive(:postgres_service_project_id).and_return(project.id).at_least(:once)
    pg = Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: project.id,
      location_id: Location::HETZNER_FSN1_ID,
      name: "assoc-table-pg",
      target_vm_size: "standard-2",
      target_storage_size_gib: 64,
    ).subject

    visit "/model/Project/#{project.ubid}"
    within(".association", text: "postgres_resources") { click_link "(table)" }
    expect(page.title).to eq "Ubicloud Admin - PostgresResource - Search"
    expect(page.all("#autoforme_content td").map(&:text)).to eq [
      "assoc-table-pg", "assoc-table-test", "hetzner-fsn1", "standard", "standard-2", "64", "none", "17", "", pg.created_at.to_s,
    ]

    server = pg.servers.first
    visit "/model/PostgresResource/#{pg.ubid}"
    within(".association", text: "servers") { click_link "(table)" }
    expect(page.title).to eq "Ubicloud Admin - PostgresServer - Search"
    expect(page.all("#autoforme_content td").map(&:text)).to eq [
      server.ubid, server.vm.ubid, "assoc-table-pg", "push", "ready", "17", "true", server.created_at.to_s,
    ]

    vm_host = create_vm_host
    boot_image = BootImage.create(name: "ubuntu-jammy", version: "20220202", vm_host_id: vm_host.id, size_gib: 14)
    visit "/model/VmHost/#{vm_host.ubid}"
    within(".association", text: "boot_images") { click_link "(table)" }
    expect(page.title).to eq "Ubicloud Admin - BootImage - Search"
    expect(page.all("#autoforme_content td").map(&:text)).to eq [
      "ubuntu-jammy", "20220202", vm_host.ubid, "14", "", boot_image.created_at.to_s,
    ]
  end

  it "handles basic pagination when browsing by class" do
    project_id = Project.create(name: "test").id
    keys = Array.new(101) { |i| SshPublicKey.create(name: "key-#{i}", public_key: "k v", project_id:) }
    page.refresh
    click_link "SshPublicKey"
    found_keys = page.all("#object-list a").map(&:text)

    click_link "More"
    found_keys.concat(page.all("#object-list a").map(&:text))

    expect(keys.map(&:name) - found_keys).to eq []
    key = SshPublicKey.last
    click_link key.name
    expect(page.title).to eq "Ubicloud Admin - SshPublicKey #{key.ubid}"
  end

  it "ignores bogus ubids when paginating" do
    project_id = Project.create(name: "test").id
    key = SshPublicKey.create(name: "key", public_key: "k v", project_id:)
    page.refresh
    click_link "SshPublicKey"
    page.visit "#{page.current_path}?after=foo"
    click_link key.name
    expect(page.title).to eq "Ubicloud Admin - SshPublicKey #{key.ubid}"
  end

  it "shows semaphores set on the object, if any" do
    fill_in "UBID, UUID, or prefix:term", with: vm_pool.ubid
    click_button "Show Object"
    expect(page.title).to eq "Ubicloud Admin - VmPool #{vm_pool.ubid}"
    expect(page).to have_no_content "Semaphores Set:"

    vm_pool.incr_destroy
    page.refresh
    expect(page).to have_content "Semaphores Set: destroy"
  end

  it "shows object's strand, if any" do
    fill_in "UBID, UUID, or prefix:term", with: vm_pool.ubid
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

  it "shows stripe data for billing info as extra" do
    expect(Config).to receive(:stripe_secret_key).and_return("secret_key").at_least(:once)
    customers_service = instance_double(Stripe::CustomerService)
    allow(StripeClient).to receive(:customers).and_return(customers_service)
    billing_info = BillingInfo.create(stripe_id: "cus_test123")
    expect(customers_service).to receive(:retrieve).with("cus_test123").and_return({"name" => "ACME Inc.", "metadata" => {"tax_id" => "123456"}, "address" => {"line1" => "123 Main St", "country" => "US"}}).at_least(:once)
    visit "/model/BillingInfo/#{billing_info.ubid}"
    expect(page.title).to eq "Ubicloud Admin - BillingInfo #{billing_info.ubid}"
    expect(page).to have_content "Stripe Data"
  end

  it "allows browsing and searching BillingInfo" do
    project = Project.create(name: "BillingTest")
    billing_info = BillingInfo.create(stripe_id: "cus_billing123")
    project.update(billing_info_id: billing_info.id)

    click_link "BillingInfo"
    click_link "Search"
    expect(page.title).to eq "Ubicloud Admin - BillingInfo - Search"

    fill_in "Project", with: project.ubid
    fill_in "Stripe", with: "cus_billing123"
    fill_in "Created at", with: billing_info.created_at.strftime("%Y-%m")
    click_button "Search"
    expect(page.all("#autoforme_content td").map(&:text)).to eq [billing_info.ubid, "cus_billing123", "BillingTest", "", billing_info.created_at.to_s]

    click_link billing_info.ubid
    expect(page.title).to eq "Ubicloud Admin - BillingInfo #{billing_info.ubid}"
  end

  it "shows stripe data for payment method as extra" do
    expect(Config).to receive(:stripe_secret_key).and_return("secret_key").at_least(:once)
    payment_methods_service = instance_double(Stripe::PaymentMethodService)
    allow(StripeClient).to receive(:payment_methods).and_return(payment_methods_service)
    billing_info = BillingInfo.create(stripe_id: "cus_test123")
    payment_method = PaymentMethod.create(billing_info_id: billing_info.id, stripe_id: "pm_1234567890")
    expect(payment_methods_service).to receive(:retrieve).with("pm_1234567890").and_return(Stripe::StripeObject.construct_from(id: "pm_1234567890", card: {brand: "Visa", last4: "1234", exp_month: 12, exp_year: 2023, country: "NL", funding: "debit", wallet: {type: "apple_pay"}, checks: {address_line1_check: "pass", cvc_check: "pass"}}))
    visit "/model/PaymentMethod/#{payment_method.ubid}"
    expect(page.title).to eq "Ubicloud Admin - PaymentMethod #{payment_method.ubid}"
    expect(page).to have_content "Stripe Data"
  end

  it "allows browsing and searching PaymentMethod" do
    billing_info = BillingInfo.create(stripe_id: "cus_payment123")
    payment_method = PaymentMethod.create(billing_info_id: billing_info.id, stripe_id: "pm_test456", fraud: true)

    click_link "PaymentMethod"
    click_link "Search"
    expect(page.title).to eq "Ubicloud Admin - PaymentMethod - Search"

    fill_in "Stripe", with: "pm_test456"
    select "True", from: "Fraud"
    fill_in "Created at", with: payment_method.created_at.strftime("%Y-%m")
    click_button "Search"
    expect(page.all("#autoforme_content td").map(&:text)).to eq [payment_method.ubid, "pm_test456", billing_info.ubid, "true", payment_method.created_at.to_s]

    click_link payment_method.ubid
    expect(page.title).to eq "Ubicloud Admin - PaymentMethod #{payment_method.ubid}"
  end

  it "allows browsing and searching PostgresResource" do
    project = Project.create(name: "PgTest")
    expect(Config).to receive(:postgres_service_project_id).and_return(project.id).at_least(:once)
    pg = Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: project.id,
      location_id: Location::HETZNER_FSN1_ID,
      name: "test-pg",
      target_vm_size: "standard-2",
      target_storage_size_gib: 64,
    ).subject

    click_link "PostgresResource"
    expect(page.title).to eq "Ubicloud Admin - PostgresResource - Browse"
    expect(page.all("#autoforme_content td").map(&:text)).to eq [
      "test-pg", "PgTest", "hetzner-fsn1", "standard", "standard-2", "64", "none", "17", "", pg.created_at.to_s,
    ]

    click_link pg.name
    expect(page.title).to eq "Ubicloud Admin - PostgresResource #{pg.ubid}"

    click_link "Ubicloud Admin"
    click_link "PostgresResource"
    click_link "Search"
    fill_in "Project", with: project.ubid
    select "standard", from: "Flavor"
    fill_in "Created at", with: pg.created_at.strftime("%Y-%m")
    click_button "Search"
    expect(page.all("#autoforme_content td").map(&:text)).to eq [
      "test-pg", "PgTest", "hetzner-fsn1", "standard", "standard-2", "64", "none", "17", "", pg.created_at.to_s,
    ]

    child_pg = Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: project.id,
      location_id: Location::HETZNER_FSN1_ID,
      name: "test-child-pg",
      target_vm_size: "standard-2",
      target_storage_size_gib: 64,
      parent_id: pg.id,
    ).subject

    click_link "Search"
    fill_in "Parent", with: pg.ubid
    click_button "Search"
    expect(page.all("#autoforme_content td").map(&:text)).to eq [
      "test-child-pg", "PgTest", "hetzner-fsn1", "standard", "standard-2", "64", "none", "17", "test-pg", child_pg.created_at.to_s,
    ]
  end

  it "allows browsing and searching PostgresServer" do
    project = Project.create(name: "PgTest")
    expect(Config).to receive(:postgres_service_project_id).and_return(project.id).at_least(:once)
    pg = Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: project.id,
      location_id: Location::HETZNER_FSN1_ID,
      name: "test-pg",
      target_vm_size: "standard-2",
      target_storage_size_gib: 64,
    ).subject
    server = pg.servers.first

    click_link "PostgresServer"
    expect(page.title).to eq "Ubicloud Admin - PostgresServer - Browse"
    expect(page.all("#autoforme_content td").map(&:text)).to eq [
      server.ubid, server.vm.ubid, "test-pg", "push", "ready", "17", "true", server.created_at.to_s,
    ]

    click_link server.ubid, match: :first
    expect(page.title).to eq "Ubicloud Admin - PostgresServer #{server.ubid}"

    click_link "Ubicloud Admin"
    click_link "PostgresServer"
    click_link "Search"
    fill_in "resource", with: pg.ubid
    fill_in "Created at", with: server.created_at.strftime("%Y-%m")
    select "push", from: "Timeline access"
    click_button "Search"
    expect(page.all("#autoforme_content td").map(&:text)).to eq [
      server.ubid, server.vm.ubid, "test-pg", "push", "ready", "17", "true", server.created_at.to_s,
    ]

    click_link "test-pg"
    expect(page.title).to eq "Ubicloud Admin - PostgresResource #{pg.ubid}"
  end

  it "renders PostgresServer detail page when resource is nil" do
    project = Project.create(name: "PgTest")
    expect(Config).to receive(:postgres_service_project_id).and_return(project.id).at_least(:once)

    resource_id = PostgresResource.generate_uuid
    server = PostgresServer.create(resource_id:, timeline: create_postgres_timeline(location_id: Location::HETZNER_FSN1_ID), version: PostgresResource::DEFAULT_VERSION)

    visit "/model/PostgresServer/#{server.ubid}"
    expect(page.title).to eq "Ubicloud Admin - PostgresServer #{server.ubid}"
  end

  it "supports downloading invoice PDF" do
    invoice = Invoice.create(
      project: Project.create(name: "stuff"),
      invoice_number: "invoice-number-378",
      content: {foo: "bar", billing_info: {country: "NL"}},
      begin_time: "2024-11-01 00:00:00",
      end_time: "2024-12-01 00:00:00",
    )

    visit "/model/Invoice/#{invoice.ubid}"
    expect(page.title).to eq "Ubicloud Admin - Invoice #{invoice.ubid}"
    expect(page).to have_link "Download PDF"

    # Redirects to presigned URL when download link is available
    presigner = instance_double(Aws::S3::Presigner)
    expect(Invoice).to receive(:blob_storage_client).and_return(instance_double(Aws::S3::Client))
    expect(Aws::S3::Presigner).to receive(:new).and_return(presigner)
    expect(presigner).to receive(:presigned_url).and_return("https://ubicloud.com/download/invoice/link.pdf")
    page.driver.get "/model/Invoice/#{invoice.ubid}/download_pdf"
    expect(page.driver.response.status).to eq 302
    expect(page.driver.response.headers["Location"]).to eq "https://ubicloud.com/download/invoice/link.pdf"

    # Raises error when download link generation fails
    expect(Invoice).to receive(:blob_storage_client).and_raise("Simulated failure")
    expect { visit "/model/Invoice/#{invoice.ubid}/download_pdf" }.to raise_error(CloverError, "Action link is not available")
  end

  it "shows quotas for project as extra" do
    project = Project.create(name: "test")
    project.add_quota(quota_id: ProjectQuota.default_quotas["GithubRunnerVCpu"]["id"], value: 400)
    create_vm(project_id: project.id, vcpus: 16)

    visit "/model/Project/#{project.ubid}"
    expect(page.title).to eq "Ubicloud Admin - Project #{project.ubid}"
    find("summary", text: "Quotas").click
    expect(page.all(".project-quota-table tbody tr").map { it.all("td").map(&:text) }).to eq [
      ["VmVCpu", "32", "16"],
      ["GithubRunnerVCpu", "400", "0"],
      ["GithubRunnerVCpuArm", "100", "0"],
      ["PostgresVCpu", "128", "0"],
      ["KubernetesVCpu", "32", "0"],
    ]
  end

  it "shows current usage for project as extra" do
    project = Project.create(name: "test")
    vm = create_vm(project_id: project.id)
    BillingRecord.create(
      project_id: project.id,
      resource_id: vm.id,
      resource_name: vm.name,
      span: Sequel::Postgres::PGRange.new(Time.now - 3600, nil),
      billing_rate_id: BillingRate.from_resource_properties("VmVCpu", vm.family, vm.location.name)["id"],
      amount: vm.vcpus,
    )

    visit "/model/Project/#{project.ubid}"
    expect(page.title).to eq "Ubicloud Admin - Project #{project.ubid}"
    find("summary", text: /Current Usage \(subtotal: \$[\d.]+, cost: \$[\d.]+\)/).click
    expect(page.all(".project-usage-table tbody tr").count).to eq 1
    expect(page.all(".project-usage-table tbody tr").first.all("td").map(&:text)).to eq ["test-vm", "VmVCpu", "standard", "61 minutes", "$0.047"]
  end

  it "converts ubids to link" do
    p = Page.create(summary: "test", tag: "a", details: {"related_resources" => [vm_pool.ubid, "cc489f465gqa5pzq04gch3162h"]})
    fill_in "UBID, UUID, or prefix:term", with: p.ubid
    click_button "Show Object"

    expect(page.title).to eq "Ubicloud Admin - Page #{p.ubid}"

    click_link vm_pool.ubid
    expect(page.title).to eq "Ubicloud Admin - VmPool #{vm_pool.ubid}"
  end

  it "shows sshable information for object, if any" do
    vm_host = Prog::Vm::HostNexus.assemble("1.2.3.4").subject
    fill_in "UBID, UUID, or prefix:term", with: vm_host.ubid
    click_button "Show Object"
    expect(page.title).to eq "Ubicloud Admin - VmHost #{vm_host.ubid}"
    expect(page).to have_content "SSH Command: ssh root@1.2.3.4"

    visit "/"
    fill_in "UBID, UUID, or prefix:term", with: vm_pool.ubid
    click_button "Show Object"
    expect(page).to have_no_content "SSH Command"
  end

  it "shows active pages on index page, grouped by related host" do
    expect(page).to have_no_content "Active Pages"

    page1 = Prog::PageNexus.assemble("some problem", %w[a], nil).subject
    page.refresh
    expect(page).to have_content "Active Pages"
    expect(page_data).to eq [
      ["", page1.ubid, "some problem", "{\"related_resources\" => []}"],
    ]
    click_link page1.ubid
    expect(page.title).to eq "Ubicloud Admin - Page #{page1.ubid}"

    page2 = Prog::PageNexus.assemble("another problem", %w[b], vm_pool.ubid).subject
    visit "/"
    expect(page_data).to eq [
      ["", page1.ubid, "some problem", "{\"related_resources\" => []}"],
      [page2.ubid, "another problem", "{\"related_resources\" => [\"#{vm_pool.ubid}\"]}"],
    ]
    click_link vm_pool.ubid
    expect(page.title).to eq "Ubicloud Admin - VmPool #{vm_pool.ubid}"

    vmh = Prog::Vm::HostNexus.assemble("1.2.3.4").subject
    pj = Project.create(name: "test")
    vm = Prog::Vm::Nexus.assemble("a a", pj.id).subject
    vm.update(vm_host_id: vmh.id)
    page3 = Prog::PageNexus.assemble("third problem", %w[c], vm.ubid).subject
    visit "/"
    expect(page_data).to eq [
      [vmh.ubid, page3.ubid, "third problem", "{\"related_resources\" => [\"#{vm.ubid}\"]}"],
      ["", page1.ubid, "some problem", "{\"related_resources\" => []}"],
      [page2.ubid, "another problem", "{\"related_resources\" => [\"#{vm_pool.ubid}\"]}"],
    ]

    click_link vmh.ubid
    expect(page.title).to eq "Ubicloud Admin - VmHost #{vmh.ubid}"

    visit "/"
    click_link vm.ubid
    expect(page.title).to eq "Ubicloud Admin - Vm #{vm.ubid}"
  end

  it "handles request for invalid ubid" do
    fill_in "UBID, UUID, or prefix:term", with: "foo"
    click_button "Show Object"
    expect(page.title).to eq "Ubicloud Admin - Search"
    expect(page).to have_content("Use prefix:term syntax to search")

    visit "/"
    fill_in "UBID, UUID, or prefix:term", with: "ts1cyaqvp5ha6j5jt8ypbyagw9"
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

  it "links to archived-record-by-id on 404 when path contains ubid" do
    ENV["DONT_RAISE_ADMIN_ERRORS"] = "1"
    vm = create_vm(name: "life-after-death")
    visit "/model/Vm/#{vm.ubid}"
    expect(page).to have_content("life-after-death")
    vm.destroy
    visit "/model/Vm/#{vm.ubid}"
    click_link "searching archived records"
    expect(page).to have_content("life-after-death")
  ensure
    ENV.delete("DONT_RAISE_ADMIN_ERRORS")
  end

  it "raises errors by default in tests" do
    expect { visit "/error" }.to raise_error(RuntimeError)
  end

  it "shows error page for errors if DONT_RAISE_ADMIN_ERRORS environment variable is set" do
    ENV["DONT_RAISE_ADMIN_ERRORS"] = "1"
    expect(Clog).to receive(:emit).with("admin route exception", instance_of(Hash)).and_call_original
    visit "/error"
    expect(page.title).to eq "Ubicloud Admin - Internal Server Error"
  ensure
    ENV.delete("DONT_RAISE_ADMIN_ERRORS")
  end

  it "handles incorrect/missing CSRF tokens" do
    schedule = Time.now + 10
    st = Strand.create(prog: "Test", label: "hop_entry", schedule:)
    fill_in "UBID, UUID, or prefix:term", with: st.ubid
    click_button "Show Object"

    find("#action-list input[name=_csrf]", visible: false).set("")
    click_button "Schedule Strand to Run Immediately"
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
    fill_in "UBID, UUID, or prefix:term", with: st.ubid
    click_button "Show Object"
    expect(page.title).to eq "Ubicloud Admin - Strand #{st.ubid}"

    click_button "Schedule Strand to Run Immediately"
    expect(page).to have_flash_notice("Scheduled strand to run immediately")
    expect(page.title).to eq "Ubicloud Admin - Strand #{st.ubid}"
    expect(st.reload.schedule).to be_within(5).of(Time.now)
  end

  it "supports adding 5 minutes to strand schedule" do
    schedule = Time.now + 10
    st = Strand.create(prog: "Test", label: "hop_entry", schedule:)
    fill_in "UBID, UUID, or prefix:term", with: st.ubid
    click_button "Show Object"
    expect(page.title).to eq "Ubicloud Admin - Strand #{st.ubid}"

    click_link "Extend Schedule"
    fill_in "minutes", with: "5"
    click_button "Extend Schedule"
    expect(page).to have_flash_notice("Extended schedule")
    expect(page.title).to eq "Ubicloud Admin - Strand #{st.ubid}"
    expect(st.reload.schedule).to be_within(5).of(schedule + 300)
  end

  it "shows empty semaphore list for strand without semaphore_names" do
    st = Strand.create(prog: "Test", label: "test")
    visit "/model/Strand/#{st.ubid}"
    expect(page.title).to eq "Ubicloud Admin - Strand #{st.ubid}"

    click_link "Increment Semaphore"
    expect(page).to have_select("name", options: [""])
  end

  it "supports incrementing semaphore of strand" do
    vp = VmPool.create(
      size: 3,
      vm_size: "standard-2",
      boot_image: "img",
      location_id: Location::HETZNER_FSN1_ID,
      storage_size_gib: 86,
    )
    st = Strand.create_with_id(vp, prog: "Vm::VmPool", label: "wait")
    visit "/model/Strand/#{st.ubid}"
    expect(page.title).to eq "Ubicloud Admin - Strand #{st.ubid}"

    click_link "Increment Semaphore"
    select "destroy", from: "name"
    select "destroying", from: "name_confirmation"
    expect { click_button "Increment Semaphore" }.to raise_error(CloverError)
    expect(st.reload.semaphores.map(&:name)).not_to include("destroy")

    visit "/model/Strand/#{st.ubid}/incr_semaphore"
    select "destroy", from: "name"
    select "destroy", from: "name_confirmation"
    click_button "Increment Semaphore"
    expect(page).to have_flash_notice("Incremented semaphore")
    expect(page.title).to eq "Ubicloud Admin - Strand #{st.ubid}"
    expect(st.reload.semaphores.map(&:name)).to include("destroy")

    Semaphore.incr(st.id, "destroying")

    visit "/model/Strand/#{st.ubid}/decr_semaphore"
    select "destroy", from: "name"
    select "destroying", from: "name_confirmation"
    expect { click_button "Decrement Semaphore" }.to raise_error(CloverError)
    expect(st.reload.semaphores.map(&:name)).to include("destroy")

    visit "/model/Strand/#{st.ubid}/decr_semaphore"
    select "destroy", from: "name"
    select "destroy", from: "name_confirmation"
    click_button "Decrement Semaphore"
    expect(page).to have_flash_notice("Decremented semaphore")
    expect(page.title).to eq "Ubicloud Admin - Strand #{st.ubid}"
    expect(st.reload.semaphores.map(&:name)).not_to include("destroy")
  end

  it "allows browsing and searching BootImage" do
    vm_host = create_vm_host
    boot_image = BootImage.create(name: "ubuntu-jammy", version: "20220202", vm_host_id: vm_host.id, size_gib: 14)

    click_link "BootImage"
    expect(page.title).to eq "Ubicloud Admin - BootImage - Browse"
    expect(page.all("#autoforme_content td").map(&:text)).to eq [
      "ubuntu-jammy", "20220202", vm_host.ubid, "14", "", boot_image.created_at.to_s,
    ]

    click_link "ubuntu-jammy"
    expect(page.title).to eq "Ubicloud Admin - BootImage #{boot_image.ubid}"

    click_link "Ubicloud Admin"
    click_link "BootImage"
    click_link "Search"
    fill_in "Vm host", with: vm_host.ubid
    click_button "Search"
    expect(page.all("#autoforme_content td").map(&:text)).to eq [
      "ubuntu-jammy", "20220202", vm_host.ubid, "14", "", boot_image.created_at.to_s,
    ]

    click_link "Search"
    fill_in "Created at", with: boot_image.created_at.strftime("%Y-%m")
    click_button "Search"
    expect(page.all("#autoforme_content td").map(&:text)).to eq [
      "ubuntu-jammy", "20220202", vm_host.ubid, "14", "", boot_image.created_at.to_s,
    ]

    boot_image.update(activated_at: Time.now)
    click_link "Search"
    fill_in "Activated at", with: boot_image.reload.activated_at.strftime("%Y-%m")
    click_button "Search"
    expect(page.all("#autoforme_content td").map(&:text)).to eq [
      "ubuntu-jammy", "20220202", vm_host.ubid, "14", boot_image.activated_at.to_s, boot_image.created_at.to_s,
    ]
  end

  it "supports removing BootImages" do
    vm_host = create_vm_host
    boot_image = BootImage.create(name: "ubuntu-jammy", version: "20220202", vm_host_id: vm_host.id, size_gib: 14)

    visit "/model/BootImage/#{boot_image.ubid}"
    expect(page.title).to eq "Ubicloud Admin - BootImage #{boot_image.ubid}"

    click_link "Remove Boot Image"
    click_button "Remove Boot Image"
    expect(page).to have_flash_notice("Boot image removal scheduled")
    expect(page.title).to eq "Ubicloud Admin - BootImage #{boot_image.ubid}"
    expect(Strand.where(prog: "RemoveBootImage", label: "start").count).to eq 1
  end

  it "supports activating BootImages" do
    vm_host = create_vm_host
    boot_image = BootImage.create(name: "ubuntu-jammy", version: "20220202", vm_host_id: vm_host.id, size_gib: 14)

    visit "/model/BootImage/#{boot_image.ubid}"
    expect(page.title).to eq "Ubicloud Admin - BootImage #{boot_image.ubid}"

    expect(boot_image.activated_at).to be_nil
    click_link "Activate Boot Image"
    click_button "Activate Boot Image"
    expect(page).to have_flash_notice("Boot image activated")
    expect(page.title).to eq "Ubicloud Admin - BootImage #{boot_image.ubid}"
    expect(boot_image.reload.activated_at).not_to be_nil
  end

  it "supports disabling BootImages" do
    vm_host = create_vm_host
    boot_image = BootImage.create(name: "ubuntu-jammy", version: "20220202", vm_host_id: vm_host.id, size_gib: 14, activated_at: Time.now)

    visit "/model/BootImage/#{boot_image.ubid}"
    expect(page.title).to eq "Ubicloud Admin - BootImage #{boot_image.ubid}"

    expect(boot_image.activated_at).not_to be_nil
    click_link "Disable Boot Image"
    click_button "Disable Boot Image"
    expect(page).to have_flash_notice("Boot image disabled")
    expect(page.title).to eq "Ubicloud Admin - BootImage #{boot_image.ubid}"
    expect(boot_image.reload.activated_at).to be_nil
  end

  it "supports restarting Vms" do
    vm = Prog::Vm::Nexus.assemble("dummy-public key", Project.create(name: "Default").id, name: "dummy-vm-1").subject
    fill_in "UBID, UUID, or prefix:term", with: vm.ubid
    click_button "Show Object"
    expect(page.title).to eq "Ubicloud Admin - Vm #{vm.ubid}"

    expect(vm.semaphores_dataset.select_map(:name)).to eq []
    click_link "Restart"
    click_button "Restart"
    expect(page).to have_flash_notice("Restart scheduled for Vm")
    expect(page.title).to eq "Ubicloud Admin - Vm #{vm.ubid}"
    expect(vm.semaphores_dataset.select_map(:name)).to eq ["restart"]
  end

  it "supports stopping Vms" do
    vm = Prog::Vm::Nexus.assemble("dummy-public key", Project.create(name: "Default").id, name: "dummy-vm-1").subject
    fill_in "UBID, UUID, or prefix:term", with: vm.ubid
    click_button "Show Object"
    expect(page.title).to eq "Ubicloud Admin - Vm #{vm.ubid}"

    expect(vm.semaphores_dataset.select_map(:name)).to eq []
    click_link "Stop"
    click_button "Stop"
    expect(page).to have_flash_notice("Stop scheduled for Vm")
    expect(page.title).to eq "Ubicloud Admin - Vm #{vm.ubid}"
    expect(vm.semaphores_dataset.select_order_map(:name)).to eq ["admin_stop", "stop"]
  end

  it "supports restarting PostgresResource" do
    project_id = Project.create(name: "Default").id
    expect(Config).to receive(:postgres_service_project_id).and_return(project_id).at_least(:once)
    pg = Prog::Postgres::PostgresResourceNexus.assemble(
      project_id:,
      location_id: Location::HETZNER_FSN1_ID,
      name: "a",
      target_vm_size: "standard-2",
      target_storage_size_gib: 64,
    ).subject
    fill_in "UBID, UUID, or prefix:term", with: pg.ubid
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
    fill_in "UBID, UUID, or prefix:term", with: vmh.ubid
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
    fill_in "UBID, UUID, or prefix:term", with: vmh.ubid
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
    fill_in "UBID, UUID, or prefix:term", with: vmh.ubid
    click_button "Show Object"
    expect(page.title).to eq "Ubicloud Admin - VmHost #{vmh.ubid}"

    expect(vmh.semaphores_dataset.select_map(:name)).to eq []
    click_link "Hardware Reset"
    click_button "Hardware Reset"
    expect(page).to have_flash_notice("Hardware reset scheduled for VmHost")
    expect(page.title).to eq "Ubicloud Admin - VmHost #{vmh.ubid}"
    expect(vmh.semaphores_dataset.select_map(:name)).to eq ["hardware_reset"]
  end

  it "supports moving VmHost to a non-github location and downloading boot images" do
    vmh = Prog::Vm::HostNexus.assemble("127.0.0.2").subject
    target_location = Location[Location::HETZNER_HEL1_ID]

    fill_in "UBID, UUID, or prefix:term", with: vmh.ubid
    click_button "Show Object"

    click_link "Move to Location"
    select target_location.display_name, from: "location"
    click_button "Move to Location"
    expect(page).to have_flash_notice("Location updated and missing boot image downloads started")
    expect(vmh.reload.location_id).to eq target_location.id

    download_strands = Strand.where(prog: "DownloadBootImage").all
    downloaded_names = download_strands.map { it.stack.first["image_name"] }.sort
    expect(downloaded_names).to eq %w[almalinux-9 debian-12 github-ubuntu-2204 github-ubuntu-2404 postgres-ubuntu-2204 ubuntu-jammy ubuntu-noble]
  end

  it "supports moving VmHost to github-runners location and downloading github images" do
    vmh = Prog::Vm::HostNexus.assemble("127.0.0.2").subject
    target_location = Location[Location::GITHUB_RUNNERS_ID]

    fill_in "UBID, UUID, or prefix:term", with: vmh.ubid
    click_button "Show Object"

    click_link "Move to Location"
    select target_location.display_name, from: "location"
    click_button "Move to Location"
    expect(page).to have_flash_notice("Location updated and missing boot image downloads started")
    expect(vmh.reload.location_id).to eq target_location.id

    download_strands = Strand.where(prog: "DownloadBootImage").all
    downloaded_names = download_strands.map { it.stack.first["image_name"] }.sort
    expect(downloaded_names).to eq %w[github-ubuntu-2204 github-ubuntu-2404]
  end

  it "supports force creating a VM on a VmHost" do
    vmh = create_vm_host
    BootImage.create(vm_host_id: vmh.id, name: "ubuntu-jammy", version: "1", size_gib: 14, activated_at: Time.now)
    project = Project.create(name: "force-vm-project")

    fill_in "UBID, UUID, or prefix:term", with: vmh.ubid
    click_button "Show Object"
    expect(page.title).to eq "Ubicloud Admin - VmHost #{vmh.ubid}"

    click_link "Force Create VM"
    fill_in "project_id", with: project.ubid
    fill_in "public_key", with: "ssh-ed25519 key"
    fill_in "name", with: "forced-vm"
    select "standard-2", from: "size"
    select "ubuntu-jammy", from: "boot_image"
    click_button "Force Create VM"
    expect(page).to have_flash_notice("VM creation scheduled")
    expect(page.title).to eq "Ubicloud Admin - VmHost #{vmh.ubid}"

    vm = Vm[name: "forced-vm"]
    expect(vm).not_to be_nil
    expect(vm.project_id).to eq project.id
    expect(vm.boot_image).to eq "ubuntu-jammy"
    expect(vm.location_id).to eq vmh.location_id
    expect(vm.arch).to eq vmh.arch
    expect(vm.ip4_enabled).to be true
    expect(Strand[vm.id].stack.first["force_host_id"]).to eq vmh.id
  end

  it "offers burstable sizes for force-create VM only when host accepts slices" do
    no_slices = create_vm_host(accepts_slices: false)
    BootImage.create(vm_host_id: no_slices.id, name: "ubuntu-jammy", version: "1", size_gib: 14, activated_at: Time.now)
    visit "/model/VmHost/#{no_slices.ubid}/force_create_vm"
    expect(page.all("select[name=size] option").map(&:text)).not_to include("burstable-1")

    with_slices = create_vm_host(accepts_slices: true)
    BootImage.create(vm_host_id: with_slices.id, name: "ubuntu-jammy", version: "1", size_gib: 14, activated_at: Time.now)
    visit "/model/VmHost/#{with_slices.ubid}/force_create_vm"
    expect(page.all("select[name=size] option").map(&:text)).to include("burstable-1")
  end

  it "deduplicates boot image options across versions in force-create VM form" do
    vmh = create_vm_host
    BootImage.create(vm_host_id: vmh.id, name: "ubuntu-jammy", version: "1", size_gib: 14, activated_at: Time.now)
    BootImage.create(vm_host_id: vmh.id, name: "ubuntu-jammy", version: "2", size_gib: 14, activated_at: Time.now)
    BootImage.create(vm_host_id: vmh.id, name: "debian-12", version: "1", size_gib: 14, activated_at: Time.now)
    visit "/model/VmHost/#{vmh.ubid}/force_create_vm"
    expect(page.all("select[name=boot_image] option").map(&:text)).to eq %w[debian-12 ubuntu-jammy]
  end

  it "rejects force-create VM when project UBID is invalid" do
    vmh = create_vm_host
    BootImage.create(vm_host_id: vmh.id, name: "ubuntu-jammy", version: "1", size_gib: 14, activated_at: Time.now)

    fill_in "UBID, UUID, or prefix:term", with: vmh.ubid
    click_button "Show Object"

    click_link "Force Create VM"
    fill_in "project_id", with: "not-a-ubid"
    fill_in "public_key", with: "ssh-ed25519 key"
    select "standard-2", from: "size"
    select "ubuntu-jammy", from: "boot_image"
    click_button "Force Create VM"
    expect(page).to have_flash_error("Invalid parameter submitted: project_id")
    expect(Vm.count).to eq 0
  end

  it "supports provisioning spare GitHubRunner" do
    ins = GithubInstallation.create(installation_id: 123, name: "test-installation", type: "User")
    ghr = GithubRunner.create(repository_name: "test-repo", label: "ubicloud", installation_id: ins.id)

    fill_in "UBID, UUID, or prefix:term", with: ghr.ubid
    click_button "Show Object"
    expect(page.title).to eq "Ubicloud Admin - GithubRunner #{ghr.ubid}"

    expect(GithubRunner.count).to eq 1
    click_button "Provision Spare Runner"
    expect(page).to have_flash_notice("Spare runner provisioned")
    expect(page.title).to eq "Ubicloud Admin - GithubRunner #{ghr.ubid}"
    expect(GithubRunner.count).to eq 2
    expect(GithubRunner.select_map([:repository_name, :label, :installation_id])).to eq([["test-repo", "ubicloud", ins.id]] * 2)
  end

  it "shows workflow job for github runner as extra" do
    workflow_job = {id: 60587328050, name: "ubicloud-standard-2", status: "in_progress"}
    installation_id = GithubInstallation.create(installation_id: 123, name: "ubicloud", type: "User").id
    runner = GithubRunner.create(repository_name: "ubicloud/ubicloud", label: "ubicloud-standard-2", installation_id:, workflow_job:)
    visit "/model/GithubRunner/#{runner.ubid}"
    expect(page.title).to eq "Ubicloud Admin - GithubRunner #{runner.ubid}"
    expect(page.all(".workflow-job-table td").map(&:text))
      .to eq ["id", "60587328050", "name", "ubicloud-standard-2", "status", "in_progress"]
  end

  it "allows browsing and searching GithubRepository" do
    ins = GithubInstallation.create(installation_id: 123, name: "test-org", type: "Organization")
    repo = GithubRepository.create(name: "test-org/test-repo", installation_id: ins.id)

    click_link "GithubRepository"
    expect(page.title).to eq "Ubicloud Admin - GithubRepository - Browse"
    expect(page.all("#autoforme_content td").map(&:text)).to eq ["test-org/test-repo", repo.created_at.to_s, repo.last_job_at.to_s]

    click_link repo.name
    expect(page.title).to eq "Ubicloud Admin - GithubRepository #{repo.ubid}"

    click_link "Ubicloud Admin"
    click_link "GithubRepository"
    click_link "Search"
    fill_in "Installation", with: ins.ubid
    fill_in "Created at", with: repo.created_at.strftime("%Y-%m")
    click_button "Search"
    expect(page.all("#autoforme_content td").map(&:text)).to eq ["test-org/test-repo", repo.created_at.to_s, repo.last_job_at.to_s]
  end

  it "links to GitHub page for GithubInstallation" do
    ins = GithubInstallation.create(installation_id: 123, name: "test-org", type: "Organization")
    visit "/model/GithubInstallation/#{ins.ubid}"
    expect(page.title).to eq "Ubicloud Admin - GithubInstallation #{ins.ubid}"
    expect(page).to have_link "GitHub Page"

    page.driver.get "/model/GithubInstallation/#{ins.ubid}/github_page"
    expect(page.driver.response.status).to eq 302
    expect(page.driver.response.headers["Location"]).to eq "http://github.com/test-org"
  end

  it "links to GitHub page for GithubRepository" do
    ins = GithubInstallation.create(installation_id: 123, name: "test-org", type: "Organization")
    repo = GithubRepository.create(name: "test-org/test-repo", installation_id: ins.id)
    visit "/model/GithubRepository/#{repo.ubid}"
    expect(page.title).to eq "Ubicloud Admin - GithubRepository #{repo.ubid}"
    expect(page).to have_link "GitHub Page"

    page.driver.get "/model/GithubRepository/#{repo.ubid}/github_page"
    expect(page.driver.response.status).to eq 302
    expect(page.driver.response.headers["Location"]).to eq "http://github.com/test-org/test-repo"
  end

  it "supports showing job log for GithubRepository" do
    ins = GithubInstallation.create(installation_id: 123, name: "test-org", type: "Organization")
    repo = GithubRepository.create(name: "test-org/test-repo", installation_id: ins.id)

    visit "/model/GithubRepository/#{repo.ubid}"
    expect(page.title).to eq "Ubicloud Admin - GithubRepository #{repo.ubid}"

    click_link "Show Job Log"
    expect(page.title).to eq "Ubicloud Admin - GithubRepository #{repo.ubid}"

    client = double
    expect(Github).to receive(:installation_client).and_return(client)
    expect(client).to receive(:workflow_run_job_logs).with("test-org/test-repo", 12345).and_return("https://example.com/logs/12345.zip")

    fill_in "job_id", with: "bad"
    click_button "Show Job Log"
    expect(page).to have_flash_error("Invalid parameter submitted: job_id")

    fill_in "job_id", with: "12345"
    click_button "Show Job Log"
    expect(page).to have_link("Download Job Log", href: "https://example.com/logs/12345.zip")
  end

  it "shows job not found for GithubRepository when job id is invalid" do
    ins = GithubInstallation.create(installation_id: 123, name: "test-org", type: "Organization")
    repo = GithubRepository.create(name: "test-org/test-repo", installation_id: ins.id)

    visit "/model/GithubRepository/#{repo.ubid}"
    click_link "Show Job Log"

    client = double
    expect(Github).to receive(:installation_client).and_return(client)
    expect(client).to receive(:workflow_run_job_logs).with("test-org/test-repo", 99999).and_raise(Octokit::NotFound)

    fill_in "job_id", with: "99999"
    click_button "Show Job Log"
    expect(page).to have_content("Job not found")
  end

  it "supports suspending and unsuspending Accounts" do
    account = create_account(with_project: false)
    fill_in "UBID, UUID, or prefix:term", with: account.ubid
    click_button "Show Object"
    expect(page.title).to eq "Ubicloud Admin - Account #{account.ubid}"

    expect(account.suspended_at).to be_nil
    click_link "Suspend"
    click_button "Suspend"
    expect(page).to have_flash_notice("Account suspended")
    expect(page.title).to eq "Ubicloud Admin - Account #{account.ubid}"
    expect(account.reload.suspended_at).not_to be_nil

    click_link "Unsuspend"
    click_button "Unsuspend"
    expect(page).to have_flash_notice("Account unsuspended")
    expect(page.title).to eq "Ubicloud Admin - Account #{account.ubid}"
    expect(account.reload.suspended_at).to be_nil
  end

  it "supports resolving Pages" do
    p = Prog::PageNexus.assemble("XYZ has an expired deadline!", ["Deadline"], Vm.generate_ubid.to_s).subject

    fill_in "UBID, UUID, or prefix:term", with: p.ubid
    click_button "Show Object"
    expect(page.title).to eq "Ubicloud Admin - Page #{p.ubid}"

    expect(p.semaphores_dataset.select_map(:name)).to eq []
    click_link "Resolve"
    click_button "Resolve"
    expect(page).to have_flash_notice("Resolve scheduled for Page")
    expect(page.title).to eq "Ubicloud Admin - Page #{p.ubid}"
    expect(p.semaphores_dataset.select_map(:name)).to eq ["resolve"]
  end

  it "supports adding credit to Projects" do
    p = Project.create(name: "Default", credit: 2)

    fill_in "UBID, UUID, or prefix:term", with: p.ubid
    click_button "Show Object"
    expect(page.title).to eq "Ubicloud Admin - Project #{p.ubid}"

    click_link "Add credit"
    fill_in "credit", with: "50.0"
    expect { click_button "Add credit" }.to change { p.reload.credit }.from(2).to(52)

    expect(page).to have_flash_notice("Added credit")
    expect(page.title).to eq "Ubicloud Admin - Project #{p.ubid}"
  end

  it "supports setting feature flags of Project" do
    p = Project.create(name: "Default")

    fill_in "UBID, UUID, or prefix:term", with: p.ubid
    click_button "Show Object"
    expect(page.title).to eq "Ubicloud Admin - Project #{p.ubid}"

    click_link "Set Feature Flag"
    path = page.current_path

    [
      ["allocator_diagnostics", "", nil],
      ["aws_alien_runners_ratio", "0.8", 0.8],
      ["enable_m6id", "false", false],
      ["visible_locations", '["eu-central-h1","eu-central-h2"]', ["eu-central-h1", "eu-central-h2"]],
      ["private_locations", '{"hetzner-fsn1": {"access_key": "ak"}}', {"hetzner-fsn1" => {"access_key" => "ak"}}],
    ].each do |name, value, expected_value|
      visit path
      select name, from: "name"
      fill_in "value", with: value
      click_button "Set Feature Flag"
      expect(p.reload.send("get_ff_#{name}")).to eq(expected_value)
      expect(page).to have_flash_notice("Set feature flag")
      expect(page.title).to eq "Ubicloud Admin - Project #{p.ubid}"
    end

    ENV["DONT_RAISE_ADMIN_ERRORS"] = "1"
    visit path
    select "free_runner_upgrade_until", from: "name"
    fill_in "value", with: "invalid_json"
    click_button "Set Feature Flag"
    expect(page).to have_content "InvalidRequest: invalid JSON for feature flag value"
  ensure
    ENV.delete("DONT_RAISE_ADMIN_ERRORS")
  end

  it "supports setting quota of Project" do
    p = Project.create(name: "Default")

    fill_in "UBID, UUID, or prefix:term", with: p.ubid
    click_button "Show Object"
    expect(page.title).to eq "Ubicloud Admin - Project #{p.ubid}"

    click_link "Set Quota"
    path = page.current_path

    # Create a new quota
    select "VmVCpu", from: "resource_type"
    fill_in "value", with: 512
    click_button "Set Quota"
    expect(page).to have_flash_notice("Set quota")
    expect(page.title).to eq "Ubicloud Admin - Project #{p.ubid}"
    expect(p.effective_quota_value("VmVCpu")).to eq(512)

    # Update existing quota
    visit path
    select "VmVCpu", from: "resource_type"
    fill_in "value", with: 1024
    click_button "Set Quota"
    expect(page).to have_flash_notice("Set quota")
    expect(p.effective_quota_value("VmVCpu")).to eq(1024)

    # Set quota to zero
    visit path
    select "VmVCpu", from: "resource_type"
    fill_in "value", with: 0
    click_button "Set Quota"
    expect(page).to have_flash_notice("Set quota")
    expect(p.effective_quota_value("VmVCpu")).to eq(0)

    2.times do
      # Remove quota when value is blank
      # Ensure value being blank doesn't add quota
      visit path
      select "VmVCpu", from: "resource_type"
      fill_in "value", with: ""
      click_button "Set Quota"
      expect(page).to have_flash_notice("Set quota")
      expect(p.effective_quota_value("VmVCpu")).to eq(32)
    end
  end

  it "lists multiple info pages with proper links and content in table format" do
    info_pages = [["first", "tag1", Time.now], ["second", "tag2", Time.now - 1], ["third", "tag3", Time.now - 2]].map do |summary, tag, created_at|
      Page.create(summary:, tag:, severity: "info", created_at:)
    end

    visit "/"
    expect(page).to have_table(class: "info-page-table")
    rows = page.all("table.info-page-table tbody tr")
    expect(rows.size).to eq(info_pages.size)

    rows.each_with_index do |row, index|
      cells = row.all("td")
      expect(cells.size).to eq(3) # Summary, Related Resources, Created At
      description_cell = cells[0]
      link = description_cell.find("a")
      info_page = info_pages[index]
      expect(link[:href]).to eq("/model/Page/#{info_page.ubid}")
      expect(link.text).to eq(info_page.summary)
      related_resources_cell = cells[1]
      expect(related_resources_cell).to have_content("No related resources")
      created_at_cell = cells[2]
      expect(created_at_cell).to have_content(/\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}/)
    end
  end

  it "does not render the info pages section when there are none" do
    visit "/"
    expect(page).to have_no_table(class: "info-page-table")
    expect(page).to have_no_css("h2", text: "Info Pages")
  end

  it "lists info pages with related resources as links in table format" do
    vm = create_vm
    info_page = Page.create(
      summary: "Test info page with related resources",
      tag: "tag1",
      details: {"related_resources" => [vm.ubid]},
      severity: "info",
    )

    visit "/"
    expect(page).to have_table(class: "info-page-table")
    rows = page.all("table.info-page-table tbody tr")
    expect(rows.size).to eq(1)

    row = rows.first
    cells = row.all("td")
    expect(cells.size).to eq(3) # Description, Related Resources, Created At
    summary_cell = cells[0]
    link = summary_cell.find("a")
    expect(link[:href]).to eq("/model/Page/#{info_page.ubid}")
    expect(link.text).to eq(info_page.summary)
    related_resources_cell = cells[1]
    expect(related_resources_cell).to have_link(vm.ubid, href: "/model/Vm/#{vm.ubid}")
    created_at_cell = cells[2]
    expect(created_at_cell).to have_content(/\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}/)
  end

  describe "local E2E" do
    before do
      project = Project.create(name: "Postgres-Service-Project")
      allow(Config).to receive(:postgres_service_project_id).and_return(project.id).at_least(:once)
      allow(Config).to receive(:local_e2e_postgres_test_project_id).and_return(nil).at_least(:once)
      click_link "Manage Local E2E"
    end

    it "shows strand status" do
      expect(page.title).to eq "Ubicloud Admin - Manage Local E2E"
      expect(page).to have_content("No data available for Active Local E2E Strands")

      local_e2e_path = page.current_path
      strand = Prog::Test::PostgresResource.assemble(provider: "metal")
      page.refresh
      expect(page.all(".local-e2e-table td").map(&:text)).to eq ["Test::PostgresResource", "start", "0", strand.ubid, '{"provider" => "metal"}', "", ""]
      click_link strand.ubid
      expect(page.title).to eq "Ubicloud Admin - Strand #{strand.ubid}"

      strand.run
      pg_ubid = UBID.to_ubid(strand.stack[0]["postgres_resource_id"])
      visit local_e2e_path
      expect(page.all(".local-e2e-table td").map(&:text)).to eq ["Test::PostgresResource", "wait_postgres_resource", "0", strand.ubid, "{\"provider\" => \"metal\", \"postgres_resource\" => \"#{pg_ubid}\"}", "", ""]
      click_link pg_ubid
      expect(page.title).to eq "Ubicloud Admin - PostgresResource #{pg_ubid}"
    end

    it "allows creation of strands" do
      local_e2e_path = page.current_path
      expect { click_button "Start Local E2E Strand" }.to raise_error(RuntimeError)

      visit local_e2e_path
      select "metal"
      expect { click_button "Start Local E2E Strand" }.to raise_error(Roda::RodaPlugins::TypecastParams::Error)

      visit local_e2e_path
      check "PostgresResource"
      expect { click_button "Start Local E2E Strand" }.to raise_error(RuntimeError)

      visit local_e2e_path
      check "PostgresResource"
      select "metal"
      click_button "Start Local E2E Strand"

      st = Strand.first(prog: "Test::PostgresResource")
      expect(st.stack[0]["local_e2e"]).to be true
      expect(page).to have_flash_notice("Started local E2E strand(s): #{st.ubid}")
      expect(page.all(".local-e2e-table td").map(&:text)).to eq ["Test::PostgresResource", "start", "0", st.ubid, '{"provider" => "metal"}', "", ""]
    end

    it "allows creation of multiple strands" do
      check "PostgresResource"
      check "HaPostgresResource"
      select "metal"
      click_button "Start Local E2E Strand"

      ha_pg_st = Strand.first(prog: "Test::HaPostgresResource")
      pg_st = Strand.first(prog: "Test::PostgresResource")
      expect(page).to have_flash_notice("Started local E2E strand(s): #{pg_st.ubid} #{ha_pg_st.ubid}")
      expect(page.all(".local-e2e-table td").map(&:text)).to eq [
        "Test::HaPostgresResource", "start", "0", ha_pg_st.ubid, '{"provider" => "metal"}', "", "",
        "Test::PostgresResource", "start", "0", pg_st.ubid, '{"provider" => "metal"}', "", "",
      ]
    end

    it "allows creation of loop strands" do
      check "PostgresResource"
      check "HaPostgresResource"
      select "metal"
      check "Loop?"
      click_button "Start Local E2E Strand"

      st = Strand.first(prog: "Test::LocalE2eLoop")
      expect(page).to have_flash_notice("Started local E2E strand(s): #{st.ubid}")
      expect(page.all(".local-e2e-table td").map(&:text)).to eq ["Test::LocalE2eLoop", "start", "0", st.ubid, "{\"progs\" => [\"PostgresResource\", \"HaPostgresResource\"], \"prog_args\" => {\"provider\" => \"metal\"}, \"starts\" => 0, \"successes\" => 0, \"failures\" => 0}", "", ""]

      st.run
      page.refresh
      child_ubid = st.children[0].ubid
      expect(page.all(".local-e2e-table td").map(&:text)).to eq [
        "Test::LocalE2eLoop", "wait", "0", st.ubid, "{\"progs\" => [\"HaPostgresResource\", \"PostgresResource\"], \"prog_args\" => {\"provider\" => \"metal\"}, \"starts\" => 1, \"successes\" => 0, \"failures\" => 0, \"current_strand\" => \"#{child_ubid}\"}", "", "",
        "Test::PostgresResource", "start", "0", child_ubid, "{\"provider\" => \"metal\"}", "", "",
      ]
    end

    it "allows pausing and unpausing strands" do
      local_e2e_path = page.current_path
      check "PostgresResource"
      select "metal"
      click_button "Start Local E2E Strand"

      click_button "Pause"
      st = Strand.first(prog: "Test::PostgresResource")
      expect(page).to have_flash_notice("Strand #{st.ubid} paused")
      expect(st.semaphores.map(&:name)).to eq ["pause"]

      st.this.update(schedule: "2100-01-01")
      click_button "Unpause"
      expect(page).to have_flash_notice("Strand #{st.ubid} unpaused")
      expect(st.semaphores(reload: true)).to eq []
      expect(st.this.get(:schedule)).to be_within(10).of(Time.now)

      st.this.update(prog: "Test::Base")
      expect { click_button "Pause" }.to raise_error(RuntimeError)

      visit local_e2e_path
      st.destroy
      click_button "Pause"
      expect(page).to have_flash_error("Strand not found, it was probably already deleted")
    end

    it "allows destroying strands" do
      check "PostgresResource"
      select "metal"
      click_button "Start Local E2E Strand"

      click_button "Destroy"
      st = Strand.first(prog: "Test::PostgresResource")
      expect(page).to have_flash_notice("Strand #{st.ubid} destroyed")
      expect(st.semaphores.map(&:name)).to eq ["destroy"]
    end

    it "allows destroying loop strand" do
      check "PostgresResource"
      select "metal"
      check "Loop?"
      click_button "Start Local E2E Strand"

      click_button "Destroy"
      st = Strand.first(prog: "Test::LocalE2eLoop")
      expect(page).to have_flash_notice("Strand #{st.ubid} destroyed")
      expect(st.semaphores.map(&:name)).to eq ["destroy"]
    end
  end

  it "shows admin list" do
    click_link "View Admin List"
    expect(page.title).to eq "Ubicloud Admin - Admin List"
    expect(page.all("#admin-list li").map(&:text)).to eq ["admin"]
    DB[:admin_account].insert(login: "foo")
    page.refresh
    expect(page.all("#admin-list li").map(&:text)).to eq ["admin", "foo"]
  end

  it "shows GitHub runner x64 VM usage" do
    project = Project.create(name: "test-project")
    project.add_quota(quota_id: ProjectQuota.default_quotas["GithubRunnerVCpu"]["id"], value: 400)
    installation = GithubInstallation.create(installation_id: 123, name: "test-installation", type: "User", project_id: project.id)
    installation_id = installation.id
    repository_name = "test-repo"
    GithubRunner.create(installation_id:, repository_name:, label: "ubicloud", allocated_at: Time.now)
    GithubRunner.create(installation_id:, repository_name:, label: "ubicloud-arm")
    GithubRunner.create(installation_id:, repository_name:, label: "ubicloud-standard-2", allocated_at: Time.now, vm_id: create_vm(vcpus: 2, allocated_at: Time.now).id)
    GithubRunner.create(installation_id:, repository_name:, label: "ubicloud-standard-4", allocated_at: Time.now, vm_id: create_vm(vcpus: 4, family: "premium").id)
    GithubRunner.create(installation_id:, repository_name:, label: "ubicloud-standard-8", allocated_at: Time.now, vm_id: create_vm(vcpus: 8, family: "m7a").id)
    GithubRunner.create(installation_id:, repository_name:, label: "ubicloud-standard-30")
    create_vm_host(location_id: Location::GITHUB_RUNNERS_ID, family: "standard", used_cores: 12, total_cores: 48)
    create_vm_host(location_id: Location::HETZNER_FSN1_ID, family: "premium", used_cores: 12, total_cores: 24)
    create_vm(boot_image: Config.github_ubuntu_2204_x64_aws_ami_version, vcpus: 4)
    create_vm(boot_image: Config.github_ubuntu_2404_x64_aws_ami_version, vcpus: 8)
    create_vm(arch: "arm64", boot_image: Config.github_ubuntu_2404_arm64_aws_ami_version, vcpus: 16)

    click_link "GitHub Runner VM Usage"
    expect(page.title).to eq "Ubicloud Admin - GitHub Runner x64 VM Usage"
    expect(page).to have_link "Show arm64"
    expect(page).to have_css("p", exact_text: "standard: vcpu 25.0%, hugepage 4.27%, spilled vcpus 12 - premium: vcpu 50.0%, hugepage 4.27%")
    expect(page.all("#content td").map(&:text)).to eq [
      "TOTAL", "", "", "400",
      "2", "1", "1", "0", "1", "0",
      "16 / 46", "2 / 14",
      "1", "0", "0", "0", "0", "0",
      "0", "1", "0", "0", "0",
      "0", "0", "1", "0",
      "test-installation", "true", "", "400",
      "2", "1", "1", "0", "1", "0",
      "16 / 46", "2 / 14",
      "1", "0", "0", "0", "0", "0",
      "0", "1", "0", "0", "0",
      "0", "0", "1", "0",
    ]

    click_link "test-installation"
    expect(page.title).to eq "Ubicloud Admin - GithubInstallation #{installation.ubid}"
  end

  it "shows GitHub runner arm64 VM usage" do
    click_link "GitHub Runner VM Usage"
    expect(page.all("#content td").map(&:text)).to eq []

    project = Project.create(name: "test-project")
    installation = GithubInstallation.create(installation_id: 123, name: "test-installation", type: "User", project_id: project.id)
    GithubRunner.create(installation_id: installation.id, repository_name: "test-repo", label: "ubicloud-arm")
    GithubRunner.create(installation_id: installation.id, repository_name: "test-repo", label: "ubicloud")
    create_vm_host(arch: "arm64", location_id: Location::GITHUB_RUNNERS_ID, family: "standard", used_cores: 6, total_cores: 24)
    create_vm(arch: "arm64", boot_image: Config.github_ubuntu_2204_arm64_aws_ami_version, vcpus: 8)

    click_link "Show arm64"

    expect(page.title).to eq "Ubicloud Admin - GitHub Runner arm64 VM Usage"
    expect(page).to have_link "Show x64"
    expect(page).to have_css("p", exact_text: "standard: vcpu 25.0%, hugepage 4.27%, spilled vcpus 8")
    expect(page.all("#content td").map(&:text)).to eq [
      "TOTAL", "", "", "100",
      "1", "0", "0", "0", "0", "0",
      "0 / 2", "0 / 0",
      "0", "0", "0", "0", "0", "0",
      "0", "0", "0", "0", "0",
      "0", "0", "0", "0",
      "test-installation", "true", "", "100",
      "1", "0", "0", "0", "0", "0",
      "0 / 2", "0 / 0",
      "0", "0", "0", "0", "0", "0",
      "0", "0", "0", "0", "0",
      "0", "0", "0", "0",
    ]
  end

  it "shows unavailable VMs" do
    project = Project.create(name: "test")
    vm = create_vm(project_id: project.id, name: "active-vm")
    Strand.create_with_id(vm, prog: "Vm::Metal::Nexus", label: "unavailable")

    visit "/"
    click_link "Show Unavailable VMs"
    click_link vm.ubid
    expect(page.title).to eq "Ubicloud Admin - Strand #{vm.ubid}"
    click_link "Subject"
    expect(page.title).to eq "Ubicloud Admin - Vm #{vm.ubid}"
  end

  it "shows footer with the commit hash" do
    now = Time.now.utc
    expect(Time).to receive(:now).and_return(now).at_least(:once)
    expect(Config).to receive(:git_commit_hash).and_return("abc1234").at_least(:once)
    visit "/"
    expect(page).to have_content(now.to_s)
    expect(page).to have_content(/commit: abc1234/)
  end

  it "shows footer without the commit hash" do
    now = Time.now.utc
    expect(Time).to receive(:now).and_return(now).at_least(:once)
    expect(Config).to receive(:git_commit_hash).and_return(nil).at_least(:once)
    visit "/"
    expect(page).to have_content(now.to_s)
    expect(page).to have_no_content(/commit:/)
  end

  it "finds both active and archived VMs by IPv4" do
    host = create_vm_host
    project = Project.create(name: "test")
    active_vm = create_vm(project_id: project.id, name: "active-vm")
    addr1 = Address.create(cidr: "172.16.0.0/24", routed_to_host_id: host.id)
    AssignedVmAddress.create(ip: "172.16.0.1/32", address_id: addr1.id, dst_vm_id: active_vm.id)

    # Archived VM
    archived_vm = create_vm(project_id: project.id, name: "archived-vm")
    addr2 = Address.create(cidr: "172.16.1.0/24", routed_to_host_id: host.id)
    assigned_addr = AssignedVmAddress.create(ip: "172.16.1.1/32", address_id: addr2.id, dst_vm_id: archived_vm.id)
    assigned_addr.destroy
    archived_vm.destroy

    visit "/vm-by-ipv4"
    fill_in "ips", with: "172.16.0.1, 172.16.1.1,,invalid-ip"
    fill_in "days", with: "10"
    click_button "Show Virtual Machines"

    expect(page).to have_content("active-vm")
    expect(page).to have_content("archived-vm")
    expect(page.find_field("days").value).to eq "10"
  end

  it "shows a message when no data available" do
    visit "/vm-by-ipv4"
    fill_in "ips", with: "172.16.0.1, 172.16.1.1,,invalid-ip"
    click_button "Show Virtual Machines"

    expect(page).to have_content("No data available for Virtual Machines table")
    expect(page.find_field("days").value).to eq "5"
  end

  describe "archived-record-by-id" do
    it "finds archived records" do
      (vm = create_vm(name: "archived-vm")).destroy
      visit "/"
      click_link "Find Archived Record by ID"

      within("#archived_record_form") do
        fill_in "id", with: vm.ubid
        click_button "Find Archived Record"
      end
      expect(page).to have_content("archived-vm")
      expect(page).to have_content(vm.id)

      within("#archived_record_form") do
        fill_in "id", with: vm.id
        click_button "Find Archived Record"
      end
      expect(page).to have_content("archived-vm")
      expect(page).to have_content(vm.id)
    end

    it "uses model_name from select when provided" do
      (vm = create_vm(name: "archived-vm")).destroy
      visit "/archived-record-by-id"

      within("#archived_record_form") do
        fill_in "id", with: vm.ubid
        select "Vm", from: "model_name"
        fill_in "days", with: "10"
        click_button "Find Archived Record"
      end
      expect(page).to have_content("archived-vm")

      within("#archived_record_form") do
        fill_in "id", with: vm.id
        select "Vm", from: "model_name"
        fill_in "days", with: "10"
        click_button "Find Archived Record"
      end
      expect(page).to have_content("archived-vm")
    end

    it "fails for invalid UBID format" do
      visit "/archived-record-by-id"

      within("#archived_record_form") do
        fill_in "id", with: "invalid-ubid"
      end
      expect { click_button "Find Archived Record" }.to raise_error CloverError, "Invalid UBID or UUID provided"
    end

    it "fails for invalid UBID with valid basic format" do
      visit "/archived-record-by-id"

      within("#archived_record_form") do
        fill_in "id", with: "xx345678901234567890123456"
      end
      expect { click_button "Find Archived Record" }.to raise_error CloverError, "Invalid UBID provided"
    end

    it "fails when can't determine model" do
      visit "/archived-record-by-id"

      within("#archived_record_form") do
        fill_in "id", with: "etcvcrc8s9hj6pgxt426mgq14y"
      end
      expect { click_button "Find Archived Record" }.to raise_error CloverError, "Could not determine model name from ID"
    end

    it "shows message when no archived records found" do
      visit "/archived-record-by-id"

      within("#archived_record_form") do
        fill_in "id", with: "vmre9wb1wy0t0kfhbd71ztqx6e"
        click_button "Find Archived Record"
      end
      expect(page).to have_content("No data available")

      within("#archived_record_form") do
        fill_in "id", with: "vmvkaj2e36325kgjq88a1994dp"
        click_button "Find Archived Record"
      end
      expect(page).to have_content("No data available")
    end

    it "respects days parameter limits" do
      (vm = create_vm(name: "archived-vm")).destroy

      visit "/archived-record-by-id"

      # Test max limit (15)
      within("#archived_record_form") do
        fill_in "id", with: vm.ubid
        fill_in "days", with: "30"
        click_button "Find Archived Record"
      end
      expect(page.find_field("days").value).to eq "15"

      # Test default (5) when no value provided
      within("#archived_record_form") do
        fill_in "id", with: vm.ubid
        fill_in "days", with: nil
        click_button "Find Archived Record"
      end
      expect(page.find_field("days").value).to eq "5"
    end
  end

  describe "audit log" do
    let(:project) { Project.create(name: "Test") }
    let(:user) { Account.create(email: "test@example.com") }

    def insert_audit_log(project_id: project.id, subject_id: user.id, object_ids: [], action: "create", ubid_type: "vm", at: Sequel::CURRENT_TIMESTAMP, id: Sequel::DEFAULT)
      DB[:audit_log].returning(:id).insert(
        id:,
        at:,
        ubid_type:,
        action:,
        project_id:,
        subject_id:,
        object_ids: Sequel.pg_array(object_ids, :uuid),
      ).first[:id]
    end

    def audit_log_content
      page.all("#audit-log-search-results td:not(:first-child):not(:only-child)").map(&:text)
    end

    it "can list audit log entries" do
      insert_audit_log

      visit "/"
      click_link "View Audit Logs"

      expect(page.title).to eq("Ubicloud Admin - Audit Log")
      expect(audit_log_content).to eq [project.ubid, "vm/create", user.ubid, ""]
    end

    it "can filter by project" do
      project2 = Project.create(name: "Test2")
      insert_audit_log(id: UBID.generate_from_time("a1", Time.now - 10).to_uuid)
      insert_audit_log(project_id: project2.id, action: "destroy", id: UBID.generate_from_time("a1", Time.now).to_uuid)

      visit "/audit-log"
      expect(audit_log_content).to eq [
        project.ubid, "vm/create", user.ubid, "",
        project2.ubid, "vm/destroy", user.ubid, "",
      ]

      fill_in "Project", with: project2.ubid
      click_button "Search"
      expect(audit_log_content).to eq [project2.ubid, "vm/destroy", user.ubid, ""]

      click_link project2.ubid
      expect(page.title).to eq("Ubicloud Admin - Project #{project2.ubid}")

      click_link "View Audit Log"
      expect(audit_log_content).to eq [project2.ubid, "vm/destroy", user.ubid, ""]

      click_link "Older Results"
      expect(audit_log_content).to eq []

      at = Date.today << 7
      insert_audit_log(at:)
      insert_audit_log(project_id: project2.id, action: "destroy", at:)
      page.refresh
      expect(audit_log_content).to eq [project2.ubid, "vm/destroy", user.ubid, ""]
    end

    it "can filter by action" do
      insert_audit_log(id: UBID.generate_from_time("a1", Time.now - 10).to_uuid)
      insert_audit_log(action: "destroy", id: UBID.generate_from_time("a1", Time.now).to_uuid)
      insert_audit_log(ubid_type: "ps", at: "2026-03-08")

      visit "/audit-log"
      expect(audit_log_content).to eq [
        project.ubid, "vm/create", user.ubid, "",
        project.ubid, "vm/destroy", user.ubid, "",
        project.ubid, "ps/create", user.ubid, "",
      ]

      fill_in "Action", with: "vm"
      click_button "Search"
      expect(audit_log_content).to eq [
        project.ubid, "vm/create", user.ubid, "",
        project.ubid, "vm/destroy", user.ubid, "",
      ]

      fill_in "Action", with: "create"
      click_button "Search"
      expect(audit_log_content).to eq [
        project.ubid, "vm/create", user.ubid, "",
        project.ubid, "ps/create", user.ubid, "",
      ]

      fill_in "Action", with: "vm/create"
      click_button "Search"
      expect(audit_log_content).to eq [project.ubid, "vm/create", user.ubid, ""]

      visit "/audit-log?limit=2"
      expect(audit_log_content).to eq [
        project.ubid, "vm/create", user.ubid, "",
        project.ubid, "vm/destroy", user.ubid, "",
      ]

      click_link "Next Page"
      expect(audit_log_content).to eq [
        project.ubid, "ps/create", user.ubid, "",
      ]

      visit "/audit-log?limit=1&action=create"
      expect(audit_log_content).to eq [
        project.ubid, "vm/create", user.ubid, "",
      ]

      click_link "Next Page"
      expect(audit_log_content).to eq [
        project.ubid, "ps/create", user.ubid, "",
      ]

      visit "/audit-log?limit=a"
      expect(audit_log_content).to eq [
        project.ubid, "vm/create", user.ubid, "",
        project.ubid, "vm/destroy", user.ubid, "",
        project.ubid, "ps/create", user.ubid, "",
      ]
    end

    it "can filter by subject UBID" do
      other_account_ubid = Account.generate_ubid
      insert_audit_log(object_ids: [other_account_ubid.to_uuid])
      insert_audit_log(subject_id: other_account_ubid.to_uuid)

      visit "/audit-log"
      fill_in "Account", with: user.ubid
      click_button "Search"
      expect(audit_log_content).to eq [project.ubid, "vm/create", user.ubid, other_account_ubid.to_s]

      user.update(name: "Test User")
      fill_in "Account", with: user.name
      click_button "Search"
      expect(audit_log_content).to eq [project.ubid, "vm/create", user.ubid, other_account_ubid.to_s]

      fill_in "Account", with: user.email
      click_button "Search"
      expect(audit_log_content).to eq [project.ubid, "vm/create", user.ubid, other_account_ubid.to_s]

      click_link user.ubid
      expect(page.title).to eq("Ubicloud Admin - Account #{user.ubid}")

      click_link "View Audit Log"
      expect(page.title).to eq("Ubicloud Admin - Audit Log")
      expect(audit_log_content).to eq [project.ubid, "vm/create", user.ubid, other_account_ubid.to_s]

      fill_in "Account", with: "NoMatch"
      click_button "Search"
      expect(audit_log_content).to eq []
    end

    it "can filter by object UBID" do
      vm = Prog::Vm::Nexus.assemble("k y", project.id, name: "vm-test").subject
      vm2 = Prog::Vm::Nexus.assemble("t y", project.id, name: "vm-test2").subject
      insert_audit_log(object_ids: [vm.id])
      insert_audit_log(object_ids: [vm2.id])

      visit "/audit-log"
      fill_in "Object", with: vm.ubid
      click_button "Search"
      expect(audit_log_content).to eq [project.ubid, "vm/create", user.ubid, vm.ubid]

      click_link vm.ubid
      expect(page.title).to eq("Ubicloud Admin - Vm #{vm.ubid}")

      click_link "View Audit Log"
      expect(audit_log_content).to eq [project.ubid, "vm/create", user.ubid, vm.ubid]
    end

    it "can filter by date, including correct pagination at same timestamp" do
      other_account_ubid = Account.generate_ubid
      Date.today
      really_old_date = Date.new(2025, 7)
      old_date = Date.new(2026)
      new_date = Date.new(2026, 5)
      al_ubid1 = UBID.generate_from_time("a1", Time.now - 10)
      al_ubid2 = UBID.generate_from_time("a1", Time.now)
      insert_audit_log(at: really_old_date, action: "update", id: al_ubid1.to_uuid)
      insert_audit_log(at: really_old_date, subject_id: other_account_ubid.to_uuid, id: al_ubid2.to_uuid)
      insert_audit_log(at: old_date)
      insert_audit_log(at: new_date, action: "destroy")

      visit "/audit-log"
      fill_in "End Date", with: "2026-08-01"
      click_button "Search"
      expect(audit_log_content).to eq [project.ubid, "vm/destroy", user.ubid, ""]

      click_link "Older Results"
      expect(audit_log_content).to eq [project.ubid, "vm/create", user.ubid, ""]

      click_link "Older Results"
      expect(audit_log_content).to eq [
        project.ubid, "vm/update", user.ubid, "",
        project.ubid, "vm/create", other_account_ubid.to_s, "",
      ]

      fill_in "End Date", with: "2025-09-01"
      click_button "Search"
      expect(audit_log_content).to eq [
        project.ubid, "vm/update", user.ubid, "",
        project.ubid, "vm/create", other_account_ubid.to_s, "",
      ]

      visit(page.current_url + "&limit=1")
      expect(audit_log_content).to eq [project.ubid, "vm/update", user.ubid, ""]

      click_link "Next Page"
      expect(audit_log_content).to eq [project.ubid, "vm/create", other_account_ubid.to_s, ""]

      visit(page.current_url[0...-1])
      expect(audit_log_content).to eq [
        project.ubid, "vm/update", user.ubid, "",
      ]

      fill_in "End Date", with: "2026-03-aa"
      click_button "Search"
      expect(audit_log_content).to eq []
    end
  end

  describe "format_bytes" do
    let(:app) { described_class.allocate }

    it "formats bytes" do
      expect(app.format_bytes(0)).to eq "0B"
      expect(app.format_bytes(1023)).to eq "1023B"
    end

    it "formats kibibytes" do
      expect(app.format_bytes(1024)).to eq "1.0KiB"
      expect(app.format_bytes(1600)).to eq "1.6KiB"
      expect(app.format_bytes(1024**2 - 1)).to eq "1024.0KiB"
    end

    it "formats mebibytes" do
      expect(app.format_bytes(1024**2)).to eq "1.0MiB"
      expect(app.format_bytes(1024**2 * 5.55)).to eq "5.6MiB"
      expect(app.format_bytes(1024**3 - 1)).to eq "1024.0MiB"
    end

    it "formats gibibytes" do
      expect(app.format_bytes(1024**3)).to eq "1.0GiB"
      expect(app.format_bytes(1024**3 * 2.25)).to eq "2.3GiB"
    end
  end

  describe "format_seconds" do
    let(:app) { described_class.allocate }

    it "formats zero" do
      expect(app.format_seconds(0)).to eq "00:00:00"
    end

    it "formats seconds only" do
      expect(app.format_seconds(45)).to eq "00:00:45"
    end

    it "formats minutes and seconds" do
      expect(app.format_seconds(125)).to eq "00:02:05"
    end

    it "formats hours, minutes, and seconds" do
      expect(app.format_seconds(3661)).to eq "01:01:01"
    end

    it "format allows for more than 2 digits in hour" do
      expect(app.format_seconds(999999)).to eq "277:46:39"
    end
  end

  describe "authentication audit log" do
    let(:user) { create_account }

    def insert_account_audit_log(account_id:, message: "login", metadata: {"ip" => "127.0.0.1"}, at: Sequel::CURRENT_TIMESTAMP)
      DB[:account_authentication_audit_log].returning(:id).insert(
        account_id:,
        message:,
        metadata: Sequel.pg_jsonb(metadata),
        at:,
      ).first[:id]
    end

    def audit_log_content
      page.all("#audit-log-search-results td:not(:first-child):not(:only-child)").map(&:text)
    end

    it "can view authentication audit log entries" do
      insert_account_audit_log(account_id: user.id, message: "login", metadata: {"ip" => "1.2.3.4"})

      click_link "View Authentication Audit Logs"

      expect(page.title).to eq("Ubicloud Admin - Authentication Audit Log")
      expect(audit_log_content).to eq ["login", user.ubid, "ip: 1.2.3.4"]
    end

    it "can filter by action" do
      insert_account_audit_log(account_id: user.id, message: "login")
      insert_account_audit_log(account_id: user.id, message: "login_failure")

      click_link "View Authentication Audit Logs"
      expect(audit_log_content).to eq [
        "login", user.ubid, "ip: 127.0.0.1",
        "login_failure", user.ubid, "ip: 127.0.0.1",
      ]

      click_link "login_failure"
      expect(audit_log_content).to eq ["login_failure", user.ubid, "ip: 127.0.0.1"]

      fill_in "Action", with: "login"
      click_button "Search"
      expect(audit_log_content).to eq ["login", user.ubid, "ip: 127.0.0.1"]
    end

    it "can filter by metadata" do
      insert_account_audit_log(account_id: user.id, message: "login", metadata: {"ip" => "1.2.3.4"})
      insert_account_audit_log(account_id: user.id, message: "login_failure", metadata: {"ip" => "9.9.9.9"})

      click_link "View Authentication Audit Logs"
      expect(audit_log_content).to eq [
        "login", user.ubid, "ip: 1.2.3.4",
        "login_failure", user.ubid, "ip: 9.9.9.9",
      ]

      click_link "ip: 1.2.3.4"
      expect(audit_log_content).to eq ["login", user.ubid, "ip: 1.2.3.4"]

      fill_in "Metadata", with: "ip=9.9.9.9"
      click_button "Search"
      expect(audit_log_content).to eq ["login_failure", user.ubid, "ip: 9.9.9.9"]
    end

    it "can filter by account name, email, and ubid" do
      user.update(name: "Test-Name")
      other = create_account("other@example.com", with_project: false)
      other.update(name: "Other-Name")
      insert_account_audit_log(account_id: user.id, message: "login")
      insert_account_audit_log(account_id: other.id, message: "login_failure")

      click_link "View Authentication Audit Logs"
      expect(audit_log_content).to eq [
        "login", user.ubid, "ip: 127.0.0.1",
        "login_failure", other.ubid, "ip: 127.0.0.1",
      ]

      click_link user.ubid
      expect(page.title).to eq("Ubicloud Admin - Account #{user.ubid}")
      click_link "View Authentication Audit Log"
      expect(audit_log_content).to eq ["login", user.ubid, "ip: 127.0.0.1"]

      fill_in "Account", with: "Other-Name"
      click_button "Search"
      expect(audit_log_content).to eq ["login_failure", other.ubid, "ip: 127.0.0.1"]

      fill_in "Account", with: user.email
      click_button "Search"
      expect(audit_log_content).to eq ["login", user.ubid, "ip: 127.0.0.1"]

      fill_in "Account", with: other.ubid
      click_button "Search"
      expect(audit_log_content).to eq ["login_failure", other.ubid, "ip: 127.0.0.1"]

      fill_in "Account", with: "not-a-ubid-or-name"
      click_button "Search"
      expect(audit_log_content).to be_empty
    end
  end

  describe "admin authentication audit log" do
    def insert_account_audit_log(account_id: DB[:admin_account].where(login: "admin").get(:id), message: "login", metadata: {"ip" => "127.0.0.1"}, at: Sequel::CURRENT_TIMESTAMP)
      DB[:admin_account_authentication_audit_log].returning(:id).insert(
        account_id:,
        message:,
        metadata: Sequel.pg_jsonb(metadata),
        at:,
      ).first[:id]
    end

    def audit_log_content
      page.all("#audit-log-search-results td:not(:first-child):not(:only-child)").map(&:text)
    end

    before do
      DB[:admin_account_authentication_audit_log].delete
    end

    it "can view authentication audit log entries" do
      insert_account_audit_log

      click_link "View Admin Authentication Audit Logs"

      expect(page.title).to eq("Ubicloud Admin - Admin Authentication Audit Log")
      expect(audit_log_content).to eq ["login", "admin", "ip: 127.0.0.1"]
    end

    it "can filter by action" do
      insert_account_audit_log
      insert_account_audit_log(message: "login_failure")

      click_link "View Admin Authentication Audit Logs"
      expect(audit_log_content).to eq [
        "login", "admin", "ip: 127.0.0.1",
        "login_failure", "admin", "ip: 127.0.0.1",
      ]

      click_link "login_failure"
      expect(audit_log_content).to eq ["login_failure", "admin", "ip: 127.0.0.1"]

      fill_in "Action", with: "login"
      click_button "Search"
      expect(audit_log_content).to eq ["login", "admin", "ip: 127.0.0.1"]
    end

    it "can filter by metadata" do
      insert_account_audit_log(metadata: {"ip" => "1.2.3.4"})
      insert_account_audit_log(message: "login_failure", metadata: {"ip" => "9.9.9.9"})

      click_link "View Admin Authentication Audit Logs"
      expect(audit_log_content).to eq [
        "login", "admin", "ip: 1.2.3.4",
        "login_failure", "admin", "ip: 9.9.9.9",
      ]

      click_link "ip: 1.2.3.4"
      expect(audit_log_content).to eq ["login", "admin", "ip: 1.2.3.4"]

      fill_in "Metadata", with: "ip=9.9.9.9"
      click_button "Search"
      expect(audit_log_content).to eq ["login_failure", "admin", "ip: 9.9.9.9"]
    end

    it "can filter by account login and ubid" do
      described_class.create_admin_account("other-admin")
      insert_account_audit_log
      insert_account_audit_log(account_id: DB[:admin_account].where(login: "other-admin").get(:id), message: "login_failure")

      click_link "View Admin Authentication Audit Logs"
      expect(audit_log_content).to eq [
        "create_account", "other-admin", "",
        "login", "admin", "ip: 127.0.0.1",
        "login_failure", "other-admin", "ip: 127.0.0.1",
      ]

      click_link "admin"
      expect(audit_log_content).to eq ["login", "admin", "ip: 127.0.0.1"]

      fill_in "Account", with: "other-admin"
      click_button "Search"
      expect(audit_log_content).to eq [
        "create_account", "other-admin", "",
        "login_failure", "other-admin", "ip: 127.0.0.1",
      ]

      fill_in "Account", with: "not-a-ubid-or-name"
      click_button "Search"
      expect(audit_log_content).to be_empty
    end
  end
end
