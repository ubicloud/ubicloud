# frozen_string_literal: true

require "capybara"
require "net/http"
require "capybara/dsl"
require "capybara/rspec"
require "capybara/cuprite"
require "puma"
require "puma/server"
require "rspec/core"

ENV["RACK_ENV"] = "test"
ENV["TZ"] = "UTC"
ENV["SHARED_CONNECTION"] = "1"

require_relative "../loader"

db_name = DB.get { current_database.function }
raise "Doesn't look like a test database (#{db_name}), not running javascript tests" unless db_name.end_with?("test")

PORT = Integer(ENV.fetch("JAVASCRIPT_TEST_PORT", "8384"))
BASE_URL = "http://localhost:#{PORT}"
TEST_USER_EMAIL = "user@example.com"
TEST_USER_PASSWORD = "Secret@Password123"

Capybara.exact = true
Capybara.default_selector = :css
Capybara.default_driver = :cuprite
Capybara.default_max_wait_time = 5
Capybara.register_driver(:cuprite) do |app|
  Capybara::Cuprite::Driver.new(app, window_size: [1600, 1000], browser_options: {timeout: 15}, base_url: BASE_URL)
end

# The application loads third-party libraries from a CDN. Each test uses a
# fresh browser context with an empty HTTP cache, so loading them from the
# CDN in every test is slow, and makes the tests fail if the CDN is slow.
# Download each library once, and serve the local copy to the browser.
module CdnCache
  DIR = File.expand_path("../tmp/javascript-test-cdn", __dir__)
  URLS = File.read(File.expand_path("../views/layouts/app.erb", __dir__)).scan(%r{https://cdn\.jsdelivr\.net/npm/[^"]+}).uniq.freeze
  CONTENT_TYPES = {".js" => "text/javascript", ".css" => "text/css"}.freeze

  def self.path(url)
    File.join(DIR, url.delete_prefix("https://cdn.jsdelivr.net/npm/"))
  end

  def self.download
    URLS.each do |url|
      path = path(url)
      next if File.file?(path)

      body = 3.times do |i|
        response = Net::HTTP.get_response(URI(url))
        break response.body if response.is_a?(Net::HTTPSuccess)
        raise "Failed to download #{url}: #{response.code}" if i == 2
      end
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite("#{path}.tmp", body)
      File.rename("#{path}.tmp", path)
    end
  end

  def self.intercept(browser)
    browser.network.intercept(pattern: "https://cdn.jsdelivr.net/*")
    browser.on(:request) do |request|
      if URLS.include?(request.url)
        request.respond(
          body: File.binread(path(request.url)),
          responseHeaders: {
            "content-type" => CONTENT_TYPES.fetch(File.extname(request.url)),
            "access-control-allow-origin" => "*",
          },
        )
      else
        request.continue
      end
    end
  end
end
CdnCache.download

# Fake inference endpoint used by the playground tests. It is served from the
# same origin as the application, so that it is allowed by the application's
# content security policy.
module FakeInference
  PATH = "/fake-inference"
  RESPONSES = Queue.new
  REQUESTS = Queue.new

  def self.call(env)
    request = Rack::Request.new(env)
    REQUESTS << {path: request.path_info, authorization: env["HTTP_AUTHORIZATION"], body: JSON.parse(request.body.read)}
    RESPONSES.pop(timeout: 5) || [500, {}, ["no fake inference response queued"]]
  end

  def self.stream(*events)
    [200, {"content-type" => "text/event-stream"}, events.map { "data: #{it.is_a?(String) ? it : JSON.generate(it)}\n\n" }]
  end
end

clover_app = Rack::Builder.parse_file("config.ru")
app = lambda do |env|
  if env["PATH_INFO"].start_with?(FakeInference::PATH)
    FakeInference.call(env)
  else
    clover_app.call(env)
  end
end

server = Puma::Server.new(app, nil, min_threads: 1, max_threads: 1, log_writer: Puma::LogWriter.null)
server.add_tcp_listener("localhost", PORT)
server.run

module JavascriptTestHelpers
  def create_account(email = TEST_USER_EMAIL, password = TEST_USER_PASSWORD, with_project: email == TEST_USER_EMAIL)
    hash = Argon2::Password.new({
      t_cost: 1,
      m_cost: 5,
      secret: Config.clover_session_secret,
    }).create(password)

    account = Account.create(email:, name: "Test User", status_id: 2)
    DB[:account_password_hashes].insert(id: account.id, password_hash: hash)
    account.create_project_with_default_policy("Default") if with_project
    account
  end

  def login(email = TEST_USER_EMAIL, password = TEST_USER_PASSWORD)
    visit "/login"
    fill_in "Email Address", with: email
    click_button "Sign in"
    fill_in "Password", with: password
    click_button "Sign in"
    expect(page).to have_title(/Dashboard\z/)
  end

  def create_vm(**)
    Vm.create(
      name: "test-vm",
      unix_user: "ubi",
      public_key: "ssh-ed25519 key",
      family: "standard",
      cores: 1,
      vcpus: 2,
      cpu_percent_limit: 200,
      cpu_burst_percent_limit: 0,
      memory_gib: 8,
      arch: "x64",
      location_id: Location::HETZNER_FSN1_ID,
      boot_image: "ubuntu-jammy",
      display_state: "running",
      **,
    )
  end

  def expect_flash_notice(message)
    expect(page).to have_css("#flash-notice", exact_text: message)
  end

  def resize(width, height)
    page.driver.browser.resize(width:, height:)
  end
end

RSpec.configure do |config|
  config.include Capybara::DSL
  config.include Capybara::RSpecMatchers
  config.include JavascriptTestHelpers

  config.before(:suite) do
    DeletedRecord.ensure_partitions(through: Time.now.utc.to_date + 1)
  end

  config.after(:suite) do
    DeletedRecord.partition_days.each { DeletedRecord.drop_partition(it) }
  end

  # capybara/rspec resets the sessions in an after hook, which runs inside
  # this around hook, so the browser is done with the server before the
  # transaction is rolled back.
  config.around do |example|
    DB.transaction(rollback: :always, auto_savepoint: true) do |conn|
      DB.temporarily_release_connection(conn) do
        example.run
      end
    end
  end

  config.after do |example|
    if example.exception && (dir = ENV["JAVASCRIPT_TEST_SCREENSHOT_DIR"])
      # rubocop:disable Lint/Debugger
      save_screenshot(File.join(dir, "#{example.full_description.gsub(/\W+/, "-")}.png"), full: true)
      # rubocop:enable Lint/Debugger
    end
  end

  config.after do
    FakeInference::RESPONSES.clear
    FakeInference::REQUESTS.clear
  end
end

RSpec.describe "Web UI JavaScript" do # rubocop:disable RSpec/DescribeClass
  let(:account) { create_account }
  let(:project) { account.projects.first }

  before do
    CdnCache.intercept(page.driver.browser)
    account
    login
  end

  describe "layout" do
    it "toggles the profile dropdown, and closes it when clicking elsewhere" do
      expect(page).to have_no_link("My Account")
      find("button[title='#{TEST_USER_EMAIL}']").click
      expect(page).to have_link("My Account")

      # Clicking inside the dropdown toggles it closed.
      find("button[title='#{TEST_USER_EMAIL}']").click
      expect(page).to have_no_link("My Account")

      find("button[title='#{TEST_USER_EMAIL}']").click
      expect(page).to have_link("My Account")

      # Clicking outside the dropdown closes it.
      find("main").click
      expect(page).to have_no_link("My Account")
    end

    it "goes back to the previous page from an error page" do
      visit "#{project.path}/dashboard"
      visit "#{project.path}/vm/does-not-exist"
      expect(page).to have_title("Ubicloud - ResourceNotFound")
      click_button "Go back"
      expect(page).to have_title(/Dashboard\z/)
    end

    it "opens and closes the mobile menu" do
      resize(600, 1000)
      expect(page).to have_no_css("#mobile-menu")
      click_button(class: "toggle-mobile-menu", match: :first)
      expect(page).to have_css("#mobile-menu.mobile-menu-open")
      within("#mobile-menu") do
        expect(page).to have_link("Compute")
        # Wait for the 300ms slide-in CSS transition, so the close button is
        # not moving when it is clicked.
        sleep 0.5
        click_button(class: "toggle-mobile-menu")
      end
      expect(page).to have_no_css("#mobile-menu.mobile-menu-open")
      expect(page).to have_no_css("#mobile-menu")
    end
  end

  describe "access control" do
    it "adds new access control entries using the template row" do
      visit "#{project.path}/user/access-control"
      expect(page).to have_css("#access-control-entries select.subject", count: 1)
      expect(page).to have_no_css("#ace-template")

      click_button "New Access Control Entry"
      click_button "New Access Control Entry"
      new_rows = all("#access-control-entries tbody tr:not(.existing-aces):not(.existing-aces-view)", minimum: 2)
      expect(new_rows.size).to eq 2
      new_ids = new_rows.flat_map { |row| row.all("select").map { it[:id] } }
      expect(new_ids).to eq %w[ace-select-1-0 ace-select-1-1 ace-select-1-2 ace-select-2-0 ace-select-2-1 ace-select-2-2]
      within(new_rows[0]) do
        find("select.subject").select("Member")
        find("select.action").select("Member")
      end
      within(new_rows[1]) do
        find("select.subject").select("Test User")
      end

      click_button "Save All"
      expect_flash_notice("Access control entries saved successfully")
      expect(page).to have_css("#access-control-entries select.subject", count: 3)
      expect(AccessControlEntry.where(project_id: project.id).count).to eq 4
    end

    it "toggles tag membership checkboxes when clicking table rows" do
      tag = SubjectTag.first(project_id: project.id, name: "Member")
      other_account = create_account("other@example.com")
      other_account.add_project(project)
      visit "#{project.path}/user/access-control/tag/subject/#{tag.ubid}"

      account_checkbox = find("#tag-membership-add tr##{account.ubid} input[type=checkbox]")
      other_checkbox = find("#tag-membership-add tr##{other_account.ubid} input[type=checkbox]")
      account_cell = find("#tag-membership-add tr##{account.ubid} td", match: :first)
      expect(account_checkbox).not_to be_checked

      # Clicking the row toggles the checkbox
      account_cell.click
      expect(account_checkbox).to be_checked
      account_cell.click
      expect(account_checkbox).not_to be_checked

      # Clicking the checkbox itself only toggles once
      other_checkbox.click
      expect(other_checkbox).to be_checked

      account_cell.click
      click_button "Add Members"
      expect_flash_notice("2 members added to subject tag")
      expect(tag.member_ids).to contain_exactly(account.id, other_account.id)
    end
  end

  describe "delete buttons" do
    it "requires typing the resource name when deletion requires confirmation" do
      key = SshPublicKey.create(project_id: project.id, name: "my-key", public_key: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEXAMPLE")
      visit "#{project.path}/ssh-public-key/#{key.ubid}"

      accept_alert("Could not confirm resource name") do
        accept_prompt(with: "wrong-name") { click_button "Delete" }
      end
      expect(page).to have_title("Ubicloud - Update SSH Public Key")
      expect(key).to exist

      accept_alert("Could not confirm resource name") do
        dismiss_prompt { click_button "Delete" }
      end
      expect(key).to exist

      accept_prompt(/Please type "my-key" to confirm deletion/, with: "my-key") { click_button "Delete" }
      expect_flash_notice("SSH public key deleted.")
      expect(key).not_to exist
    end

    it "requires accepting the confirmation when deletion does not require typing the name" do
      firewall = Firewall.create(project_id: project.id, location_id: Location::HETZNER_FSN1_ID, name: "my-firewall")
      rule = FirewallRule.create(firewall_id: firewall.id, cidr: "1.2.3.0/24", port_range: Sequel.pg_range(22..22))
      visit "#{project.path}#{firewall.path}/networking"

      dismiss_confirm("Are you sure to delete?") { find("#fwr-delete-#{rule.ubid} button").click }
      expect(rule).to exist

      accept_confirm("Are you sure to delete?") { find("#fwr-delete-#{rule.ubid} button").click }
      expect_flash_notice("Firewall rule deleted")
      expect(rule).not_to exist
    end
  end

  describe "virtual machine serial log" do
    let(:vm) do
      vm_host_id = VmHost.generate_uuid
      Sshable.create_with_id(vm_host_id)
      VmHost.create_with_id(vm_host_id, location_id: Location::HETZNER_FSN1_ID, allocation_state: "accepting", arch: "x64", family: "standard", total_cores: 48, used_cores: 2, total_hugepages_1g: 375, used_hugepages_1g: 16)
      create_vm(project_id: project.id, vm_host_id:)
    end

    it "reloads the page while the serial log is being fetched" do
      rc = RunCommand.create(vm_id: vm.id, command: "fetch_serial_log", status: "created", run_at: Time.now)
      visit "#{project.path}#{vm.path}/serial-log"
      expect(page).to have_content("Fetching serial console log")
      expect(page).to have_button("Fetch latest", disabled: true)

      rc.update(status: "succeeded", output: (1..500).map { "line #{it}" }.join("\n"))
      # The page automatically refreshes every 5 seconds while the log is being fetched.
      expect(page).to have_content("line 500", wait: 10)
      expect(page).to have_no_content("Fetching serial console log")
    end

    it "shows a countdown on the fetch button until fetching is allowed again" do
      # Use a whole second for run_at, as the button's countdown has second precision.
      RunCommand.create(vm_id: vm.id, command: "fetch_serial_log", status: "succeeded", output: "booted\n", run_at: Time.at(Time.now.to_i - 45))
      visit "#{project.path}#{vm.path}/serial-log"
      expect(page).to have_content("booted")

      button = find("button[name=refresh]")
      expect(button).to be_disabled
      expect(button).to have_text(/\AFetch latest \(\s*\d\d\s*s\)\z/)
      seconds = Integer(button.find("span").text, 10)
      expect(seconds).to be_between(1, 16)

      # The countdown decreases every second
      if seconds > 1
        lower = Regexp.union((1...seconds).map { format("%02d", it) })
        expect(button).to have_css("span", text: /\A#{lower}\z/)
      end

      expect(button).to have_text(/\AFetch latest\z/, wait: seconds + 3)
      expect(button).not_to be_disabled
      click_button "Fetch latest"
      expect(page).to have_content("Fetching serial console log")
    end
  end

  describe "GitHub runners" do
    let(:installation) { GithubInstallation.create(installation_id: 123, project_id: project.id, name: "test-org", type: "Organization") }

    before do
      allow(Config).to receive(:github_app_name).and_return("runner-app")
    end

    it "expands and collapses cache entries for each repository" do
      repo1 = GithubRepository.create(name: "test-org/repo1", installation_id: installation.id)
      repo2 = GithubRepository.create(name: "test-org/repo2", installation_id: installation.id)
      entry1 = GithubCacheEntry.create(key: "key-1", version: "v1", scope: "main", repository_id: repo1.id, created_by: repo1.id, committed_at: Time.now, size: 1024)
      entry2 = GithubCacheEntry.create(key: "key-2", version: "v1", scope: "main", repository_id: repo2.id, created_by: repo2.id, committed_at: Time.now, size: 1024)
      visit "#{project.path}/github/#{installation.ubid}/cache"

      expect(page).to have_no_content("key-1")
      expect(page).to have_no_content("key-2")

      find("tr.cache-group-row[data-repository=#{repo1.ubid}] th", match: :first).click
      expect(page).to have_css("tr.cache-group-row.active[data-repository=#{repo1.ubid}]")
      expect(page).to have_content("key-1")
      expect(page).to have_no_content("key-2")

      find("tr.cache-group-row[data-repository=#{repo2.ubid}] th", match: :first).click
      expect(page).to have_content("key-2")

      find("tr.cache-group-row[data-repository=#{repo1.ubid}] th", match: :first).click
      expect(page).to have_no_css("tr.cache-group-row.active[data-repository=#{repo1.ubid}]")
      expect(page).to have_no_content("key-1")
      expect(page).to have_content("key-2")

      # Deleting all entries for a repository uses a custom confirmation message
      accept_alert("Could not confirm resource name") do
        accept_prompt(/\AAre you sure you want to delete all cache entries for this repository\?\nPlease type "delete all"/, with: "no") do
          click_button "delete-all-#{repo1.ubid}"
        end
      end
      expect(Strand.where(prog: "Github::DeleteCacheEntries").count).to eq 0

      accept_prompt(with: "delete all") { click_button "delete-all-#{repo1.ubid}" }
      expect_flash_notice("Scheduled deletion of existing cache entries")
      expect(Strand.where(prog: "Github::DeleteCacheEntries").count).to eq 1
      expect(entry1).to exist
      expect(entry2).to exist
    end

    it "switches between installations using the dropdown, and toggles settings" do
      other = GithubInstallation.create(installation_id: 456, project_id: project.id, name: "other-org", type: "Organization")
      visit "#{project.path}/github/#{installation.ubid}/setting"

      expect(page).to have_no_link("other-org")
      click_button "test-org"
      click_link "other-org"
      expect(page).to have_current_path("#{project.path}/github/#{other.ubid}/runner")

      visit "#{project.path}/github/#{installation.ubid}/setting"
      expect(installation.reload.cache_enabled).to be true
      expect(page).to have_css("#cache_enabled_toggle .active")
      within("#cache_enabled_toggle") { click_button }
      expect_flash_notice("Ubicloud transparent cache disabled")
      expect(installation.reload.cache_enabled).to be false
      expect(page).to have_no_css("#cache_enabled_toggle .active")
      expect(page).to have_css("#cache_enabled_toggle button")
    end
  end

  describe "resource creation form" do
    def pick(name, value)
      find("input[name=#{name}][value='#{value}']:not([disabled])", visible: :all).find(:xpath, "..").click
    end

    def visible_options(name)
      all("input[name=#{name}]").map { "#{it.value}#{"*" if it.checked?}" }
    end

    def expect_options(**expected)
      expected.each do |name, values|
        expect(page).to have_css("input[name=#{name}]", count: values.size)
        expect(visible_options(name)).to eq values
      end
    end

    def visible_subnets
      all("select[name=private_subnet_id] option").map { "#{it.text}#{"*" if it.selected?}" }
    end

    it "updates the available child options when parent options are changed" do
      fsn1 = Location[Location::HETZNER_FSN1_ID]
      hel1 = Location[Location::HETZNER_HEL1_ID]
      PrivateSubnet.create(name: "my-subnet", location_id: fsn1.id, project_id: project.id, net6: "fd10:9b0b:6b4b:8fbb::/64", net4: "10.0.0.0/26")
      visit "#{project.path}/vm/create"

      expect(visible_options("location").select { it.end_with?("*") }).to eq ["#{fsn1.ubid}*"]
      expect_options(
        family: %w[standard* burstable],
        size: %w[standard-2* standard-4 standard-8 standard-16 standard-30 standard-60],
        storage_size: %w[40* 80],
      )
      expect(visible_subnets).to eq ["Default*", "my-subnet", "New Private Subnet"]

      # Changing the size updates the storage sizes
      pick("size", "standard-4")
      expect_options(storage_size: %w[80* 160])

      # Changing the family updates the sizes and storage sizes
      pick("family", "burstable")
      expect_options(size: %w[burstable-1* burstable-2], storage_size: %w[10* 20])
      pick("family", "standard")
      expect_options(size: %w[standard-2* standard-4 standard-8 standard-16 standard-30 standard-60], storage_size: %w[40* 80])

      # Explicitly selected options are kept when changing the parent option,
      # if they are still available.
      pick("storage_size", "80")
      select "my-subnet", from: "private_subnet_id"
      pick("location", hel1.ubid)
      expect_options(
        family: %w[standard*],
        size: %w[standard-2* standard-4 standard-8 standard-16 standard-30 standard-60],
        storage_size: %w[40 80*],
      )
      expect(visible_subnets).to eq ["Default*", "New Private Subnet"]

      pick("location", fsn1.ubid)
      expect_options(family: %w[standard* burstable], storage_size: %w[40 80*])
      expect(visible_subnets).to eq ["Default*", "my-subnet", "New Private Subnet"]

      pick("location", hel1.ubid)
      fill_in "Name", with: "test-vm"
      fill_in "SSH Public Key", with: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEXAMPLEKEYEXAMPLEKEYEXAMPLEKEYEXAMPLEKEY"
      click_button "Create"
      expect_flash_notice("'test-vm' will be ready in a few minutes")
      vm = Vm.first(name: "test-vm")
      expect(vm.location_id).to eq hel1.id
      expect(vm.family).to eq "standard"
      expect(vm.vcpus).to eq 2
      expect(vm.vm_storage_volumes.first.size_gib).to eq 80
    end
  end

  describe "multi-value inputs" do
    it "adds and removes rows" do
      allow(Config).to receive(:private_link_service_enabled).and_return(true)
      project.set_ff_private_link_service_aws(true)
      visit "#{project.path}/private-link-service/aws/create"

      within("#ports") do
        expect(page).to have_css(".multi-input-row", count: 2)
        expect(all("input[name='ports[]']").map(&:value)).to eq %w[5432 6432]
      end

      # Adding a row clones the last row, clearing values and ids
      click_button "Add another port"
      within("#ports") do
        expect(page).to have_css(".multi-input-row", count: 3)
        rows = all(".multi-input-row")
        expect(rows.last.all("input").map(&:value)).to eq ["", ""]
        expect(rows.last.all("input").map { it[:id] }).to eq ["", ""]
        rows.last.find_field(name: "ports[]").fill_in(with: "8080")
        rows.last.find_field(name: "target_ports[]").fill_in(with: "80")

        # Removing a row
        rows.first.click_button "Remove"
        expect(page).to have_css(".multi-input-row", count: 2)
        expect(all("input[name='ports[]']").map(&:value)).to eq %w[6432 8080]
      end

      # Removing the last remaining row only clears it
      within("#allowed-principals") do
        find_field(name: "allowed_principals[]").fill_in(with: "arn:aws:iam::123456789012:root")
        click_button "Remove"
        expect(page).to have_css(".multi-input-row", count: 1)
        expect(page).to have_field(name: "allowed_principals[]", with: "")
      end

      # Select inputs are handled as well
      within("#aws-supported-regions") do
        first_region = all("select[name='aws_supported_regions[]'] option")[1].text
        find("select[name='aws_supported_regions[]']").select(first_region)
      end
      click_button "Add another region"
      within("#aws-supported-regions") do
        expect(page).to have_css(".multi-input-row", count: 2)
        expect(all("select[name='aws_supported_regions[]']").map(&:value)).to match [/\A\S+\z/, ""]
        all(".multi-input-row").last.click_button "Remove"
        expect(page).to have_css(".multi-input-row", count: 1)
        click_button "Remove"
        expect(find("select[name='aws_supported_regions[]']").value).to eq ""
      end
    end
  end

  describe "Kubernetes metrics charts" do
    it "filters chart series by node" do
      allow(Config).to receive(:kubernetes_service_project_id).and_return(Project.create(name: "kubernetes-service").id)
      kc = Prog::Kubernetes::KubernetesClusterNexus.assemble(
        name: "test-kc",
        version: Option.selectable_kubernetes_versions.first,
        project_id: project.id,
        location_id: Location::HETZNER_FSN1_ID,
      ).subject
      %w[node-1 node-2].each do |name|
        KubernetesNode.create(vm_id: create_vm(name:, project_id: project.id).id, kubernetes_cluster_id: kc.id)
      end
      allow_any_instance_of(KubernetesCluster).to receive(:display_state).and_return("running")

      client = Object.new
      client.define_singleton_method(:query_range) do |query:, start_ts:, end_ts:|
        values = (start_ts..end_ts).step(60).map { [it, "1"] }
        case query
        when /node_disk_reads_completed_total/
          %w[node-1 node-2].map { {"labels" => {"instance" => it}, "values" => values} }
        when /apiserver_request:rate5m/
          [{"labels" => {"code" => "200"}, "values" => values}]
        else
          []
        end
      end
      allow(VictoriaMetricsResource).to receive(:client_for_project).and_return(client)

      visit "#{project.path}#{kc.path}/charts"
      expect(page).to have_select("node-filter", options: ["All nodes", "node-1", "node-2"], selected: "All nodes")

      series_names = lambda do |key|
        find("##{key}-chart").hover
        find("##{key}-chart div", text: /●/, match: :first).all("span", text: /●/).map { it.text.delete_prefix("● ") }
      end
      expect(series_names.call("disk_io")).to eq ["Reads node-1", "Reads node-2"]
      expect(series_names.call("api_request_rate")).to eq ["200"]

      select "node-2", from: "node-filter"
      expect(series_names.call("disk_io")).to eq ["Reads node-2"]
      # Series that do not belong to a node are always shown
      expect(series_names.call("api_request_rate")).to eq ["200"]

      # The filter also applies to newly loaded data
      click_button "Refresh"
      # Wait for the refreshed data to be rendered (there is no DOM change to wait for)
      sleep 1
      expect(series_names.call("disk_io")).to eq ["Reads node-2"]

      select "All nodes", from: "node-filter"
      expect(series_names.call("disk_io")).to eq ["Reads node-1", "Reads node-2"]
    end
  end

  describe "inference playground" do
    let(:fake_url) { "#{BASE_URL}#{FakeInference::PATH}" }

    let!(:endpoints) do
      ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "inference-ps", location_id: Location::HETZNER_FSN1_ID).subject
      lb = LoadBalancer.create(private_subnet_id: ps.id, name: "inference-lb", health_check_endpoint: "/up", project_id: project.id)
      offline_lb = LoadBalancer.create(private_subnet_id: ps.id, name: "offline-lb", health_check_endpoint: "/up", project_id: project.id)
      [
        ["text-model", lb, {capability: "Text Generation"}],
        ["vision-model", lb, {capability: "Text Generation", multimodal: true}],
        ["unreachable-model", offline_lb, {capability: "Text Generation"}],
      ].to_h do |model_name, load_balancer, tags|
        [model_name, InferenceEndpoint.create(name: model_name, model_name:, project_id: project.id, is_public: false, visible: true, load_balancer_id: load_balancer.id, location_id: Location::HETZNER_FSN1_ID, vm_size: "size", replica_count: 1, boot_image: "image", storage_volumes: [], engine_params: "", engine: "vllm", private_subnet_id: ps.id, tags:)]
      end
    end

    let!(:api_key) { ApiKey.create_inference_api_key(project) }

    before do
      url = fake_url
      allow_any_instance_of(LoadBalancer).to receive(:health_check_url).and_wrap_original do |m, *|
        # The offline endpoint uses a URL not allowed by the content security
        # policy, so that fetching from it fails.
        (m.receiver.name == "offline-lb") ? "http://localhost:#{PORT + 1}" : url
      end
    end

    def submit_prompt(prompt)
      fill_in "inference_prompt", with: prompt
      click_button "Submit"
    end

    def next_request
      FakeInference::REQUESTS.pop(timeout: 5) || raise("no request received")
    end

    def message(id)
      find("#inference_message_#{id}")
    end

    def message_info(id)
      find("#inference_message_info_#{id}")
    end

    it "streams chat responses, keeping the conversation history" do
      visit "#{project.path}/inference-playground"
      expect(page).to have_select("inference_endpoint", selected: "text-model")
      expect(page).to have_content("There are no messages yet.")
      expect(page).to have_field("inference_files", disabled: true)

      # Advanced settings are hidden by default
      expect(page).to have_no_field("inference_system")
      check "Show advanced settings"
      fill_in "inference_temperature", with: "0.5"
      fill_in "inference_top_p", with: "0.9"
      fill_in "inference_system", with: "You are helpful."
      uncheck "Show advanced settings"
      expect(page).to have_no_field("inference_system")

      FakeInference::RESPONSES << FakeInference.stream(
        {choices: [{delta: {reasoning_content: "Thinking\n\nabout it"}}]},
        {choices: [{delta: {content: "Hello **world**"}}]},
        "not json",
        {choices: [{delta: {}}]},
        {choices: [{delta: {content: "!"}}], usage: {prompt_tokens: 12, completion_tokens: 3}},
        "[DONE]",
      )
      submit_prompt("Say hello")

      request = next_request
      expect(request[:path]).to eq "#{FakeInference::PATH}/v1/chat/completions"
      expect(request[:authorization]).to eq "Bearer #{api_key.key}"
      expect(request[:body]).to eq(
        "model" => "text-model",
        "messages" => [
          {"role" => "system", "content" => "You are helpful."},
          {"role" => "user", "content" => [{"type" => "text", "text" => "Say hello"}]},
        ],
        "stream" => true,
        "stream_options" => {"include_usage" => true},
        "temperature" => 0.5,
        "top_p" => 0.9,
      )

      expect(page).to have_no_content("There are no messages yet.")
      expect(message(0)).to have_text("Say hello")
      expect(message(1)).to have_css("strong", text: "world")
      expect(message(1)).to have_text("Hello world!")
      expect(message(1)).to have_xpath(".//div[div[normalize-space()='Reasoning']]", text: /\AReasoning\s+Thinking\s+about it\z/)
      expect(message_info(1)).to have_text("Usage: 12 input tokens and 3 output tokens.")
      expect(page).to have_field("inference_prompt", with: "")
      expect(page).to have_button("Submit")

      # Copying a message briefly shows a check icon
      find_by_id("copy_inference_message_1").click
      expect(page).to have_css("#inference_icon_1 path[d^='m4.5 12.75']", visible: :all)
      expect(page).to have_no_css("#inference_icon_1 path[d^='m4.5 12.75']", visible: :all, wait: 3)

      # Reasoning can also be included in the content using think tags
      FakeInference::RESPONSES << FakeInference.stream({choices: [{delta: {content: "<think>Pondering</think>Goodbye"}}]})
      submit_prompt("Say goodbye")
      expect(next_request[:body]["messages"].map { [it["role"], it["content"].is_a?(Array) ? it["content"][0]["text"] : it["content"]] }).to eq [
        ["system", "You are helpful."],
        ["user", "Say hello"],
        ["assistant", "Hello **world**!"],
        ["user", "Say goodbye"],
      ]
      expect(message(3)).to have_xpath(".//div[div[normalize-space()='Reasoning']]", text: /\AReasoning\s+Pondering\z/)
      expect(message(3)).to have_text(/Goodbye\z/)

      # Starting a new chat clears the history
      click_button "Start a new chat"
      expect(page).to have_content("There are no messages yet.")
      expect(page).to have_no_css("#inference_message_0")

      FakeInference::RESPONSES << FakeInference.stream({choices: [{delta: {content: "Hi again"}}]})
      submit_prompt("Hello again")
      expect(next_request[:body]["messages"].map { it["role"] }).to eq %w[system user]
      expect(message(0)).to have_text("Hello again")
      expect(message(1)).to have_text("Hi again")
    end

    it "requires a prompt, endpoint, and API key" do
      visit "#{project.path}/inference-playground"

      accept_alert("Please enter a prompt.") { click_button "Submit" }

      fill_in "inference_prompt", with: "Hello"
      select "Pick an endpoint", from: "inference_endpoint"
      accept_alert("Please select an inference endpoint.") { click_button "Submit" }

      select "text-model", from: "inference_endpoint"
      select "Pick a key", from: "inference_api_key"
      accept_alert("Please select an inference api key.") { click_button "Submit" }

      expect(page).to have_content("There are no messages yet.")
      expect(FakeInference::REQUESTS).to be_empty
    end

    it "shows errors from the inference endpoint" do
      visit "#{project.path}/inference-playground"

      FakeInference::RESPONSES << [500, {}, ["error"]]
      submit_prompt("Hello")
      expect(message_info(1)).to have_text("An error occurred: Response status: 500")
      expect(page).to have_button("Submit")

      select "unreachable-model", from: "inference_endpoint"
      submit_prompt("Hello")
      expect(message_info(3)).to have_text("Unable to get a response from the endpoint. This may be due to network connectivity or permission-related issues.")
      expect(page).to have_button("Submit")
    end

    it "stops a response that is being streamed" do
      visit "#{project.path}/inference-playground"

      release = Queue.new
      body = Enumerator.new do |y|
        y << "data: #{JSON.generate(choices: [{delta: {content: "Partial"}}])}\n\n"
        release.pop(timeout: 10)
        y << "data: #{JSON.generate(choices: [{delta: {content: " response"}}])}\n\n"
      end
      FakeInference::RESPONSES << [200, {"content-type" => "text/event-stream"}, body]
      submit_prompt("Hello")

      expect(message(1)).to have_text("Partial")
      expect(page).to have_field("inference_files", disabled: true)
      click_button "Stop"
      expect(message_info(1)).to have_text("Request aborted.")
      expect(page).to have_button("Submit")
      expect(message(1)).to have_text(/\APartial\z/)
    ensure
      release << true
    end

    it "attaches files when using multimodal models" do
      vision_model = endpoints["vision-model"]
      visit "#{project.path}/inference-playground##{vision_model.ubid}"
      expect(page).to have_select("inference_endpoint", selected: "vision-model")
      expect(page).to have_field("inference_files", disabled: false)

      select "text-model", from: "inference_endpoint"
      expect(page).to have_field("inference_files", disabled: true)
      select "vision-model", from: "inference_endpoint"
      expect(page).to have_field("inference_files", disabled: false)

      # Use a directory under the working directory, as a sandboxed browser
      # may not be able to read files in the system temporary directory.
      FileUtils.mkdir_p("tmp")
      dir = File.expand_path(Dir.mktmpdir("javascript-test", "tmp"))
      pdf = File.join(dir, "doc.pdf")
      File.write(pdf, "%PDF-1.4\n%%EOF\n")
      txt = File.join(dir, "notes.txt")
      File.write(txt, "notes")

      FakeInference::RESPONSES << FakeInference.stream({choices: [{delta: {content: "Nice logo"}}]})
      attach_file("inference_files", [File.expand_path("public/logo-white.png"), pdf])
      submit_prompt("Describe these")

      content = next_request[:body]["messages"][0]["content"]
      expect(content.size).to eq 3
      expect(content[0]).to eq("type" => "text", "text" => "Describe these")
      expect(content[1]["type"]).to eq "image_url"
      expect(content[1]["image_url"]["url"]).to eq "data:image/png;base64,#{Base64.strict_encode64(File.binread("public/logo-white.png"))}"
      expect(content[2]).to eq("type" => "file", "file" => {"filename" => "doc.pdf", "file_data" => "data:application/pdf;base64,#{Base64.strict_encode64(File.binread(pdf))}"})
      expect(page).to have_content("Attached 2 file(s).")
      expect(message(1)).to have_text("Nice logo")
      expect(page).to have_field("inference_files", disabled: false)

      attach_file("inference_files", txt)
      fill_in "inference_prompt", with: "Read this"
      accept_alert("Failed to read file(s): Unsupported file type text/plain for file notes.txt. Only images and PDFs are supported.") do
        click_button "Submit"
      end
      expect(page).to have_no_css("#inference_message_2")
    ensure
      FileUtils.rm_rf(dir) if dir
    end
  end

  describe "PostgreSQL" do
    let(:postgres_project) { Project.create(name: "postgres-service") }

    let(:pg) do
      pg = Prog::Postgres::PostgresResourceNexus.assemble(
        project_id: project.id,
        location_id: Location::HETZNER_FSN1_ID,
        name: "test-pg",
        target_vm_size: "standard-2",
        target_storage_size_gib: 128,
        target_version: "17",
      ).subject
      pg.strand.update(label: "wait")
      pg
    end

    let(:pg_path) { "#{project.path}#{pg.path}" }

    before do
      allow(Config).to receive(:postgres_service_project_id).and_return(postgres_project.id)
    end

    it "adds and removes configuration entries" do
      pg.update(user_config: {"max_connections" => "100", "work_mem" => "4MB"}, pgbouncer_user_config: {"max_client_conn" => "500"})
      visit "#{pg_path}/config"

      within(".pg-config-card") do
        expect(page).to have_css(".config-group", count: 2)

        # Removing an entry
        find_field(with: "work_mem").ancestor(".config-group").find(".delete-config-btn").click
        expect(page).to have_css(".config-group", count: 1)
        expect(page).to have_no_field(with: "work_mem")

        # Adding an entry
        within(".new-config") do
          fill_in placeholder: "New Key", with: "statement_timeout"
          fill_in placeholder: "New Value", with: "1000"
          find(".add-config-btn").click
          expect(page).to have_field(placeholder: "New Key", with: "")
          expect(page).to have_field(placeholder: "New Value", with: "")
        end
        expect(page).to have_css(".config-group", count: 2)
        expect(page).to have_field(with: "statement_timeout")
        expect(page).to have_field(with: "1000")

        within(".new-config") do
          fill_in placeholder: "New Key", with: "lock_timeout"
          fill_in placeholder: "New Value", with: "2000"
          find(".add-config-btn").click
        end
        expect(page).to have_css(".config-group", count: 3)

        # Removing an added entry
        find_field(with: "lock_timeout").ancestor(".config-group").find(".delete-config-btn").click
        expect(page).to have_css(".config-group", count: 2)
      end

      within(".pgbouncer-config-card .new-config") do
        fill_in placeholder: "New Key", with: "default_pool_size"
        fill_in placeholder: "New Value", with: "20"
        find(".add-config-btn").click
      end

      click_button "Save"
      expect_flash_notice("Configuration updated successfully.")
      pg.reload
      expect(pg.user_config).to eq("max_connections" => "100", "statement_timeout" => "1000")
      expect(pg.pgbouncer_user_config).to eq("max_client_conn" => "500", "default_pool_size" => "20")
    end

    it "keeps options marked unavailable by the server disabled when changing parent options" do
      allow_any_instance_of(PostgresResource).to receive(:observed_disk_usage_gib).and_return(60)
      visit "#{pg_path}/resize"

      storage_options = lambda do
        all("input[name=storage_size]", visible: :all).filter_map do |input|
          label = input.find(:xpath, "..", visible: :all)
          next unless label.visible?
          "#{input.value}#{"*" if input.checked?}#{" disabled" if input.disabled?}#{" unavailable" if label[:class].split.include?("option-unavailable")}"
        end
      end
      pick = ->(name, value) { find("input[name=#{name}][value='#{value}']:not([disabled])", visible: :all).find(:xpath, "..").click }

      # 64 GB cannot hold the 60 GB used
      expect(storage_options.call).to eq ["64 disabled unavailable", "128*", "256"]
      expect(page).to have_content("Too small for 60 GB used")

      pick.call("size", "standard-4")
      expect(storage_options.call).to eq ["128*", "256", "512"]
      pick.call("storage_size", "256")

      pick.call("size", "standard-2")
      expect(storage_options.call).to eq ["64 disabled unavailable", "128", "256*"]

      # If all options are unavailable, the first is still checked
      pick.call("family", "hobby")
      expect(storage_options.call).to eq ["16* disabled unavailable", "32 disabled unavailable", "64 disabled unavailable"]

      pick.call("family", "standard")
      expect(storage_options.call).to eq ["64 disabled unavailable", "128*", "256"]
    end

    it "requires confirmation to restart the database" do
      visit "#{pg_path}/settings"

      dismiss_confirm("Are you sure to restart?") { click_button "Restart" }
      expect(Semaphore.where(name: "restart").count).to eq 0

      accept_confirm("Are you sure to restart?") { click_button "Restart" }
      expect_flash_notice("'test-pg' will be restarted in a few seconds")
      expect(Semaphore.where(name: "restart").count).to eq 1
    end

    it "switches connection information formats, and reveals and copies connection strings" do
      allow(Config).to receive(:postgres_service_hostname).and_return("pg.ubicloud.com")
      DnsZone.create(project_id: postgres_project.id, name: "pg.ubicloud.com")
      pg.update(hostname_version: "v2")
      pg.private_subnet.connect_subnet(Prog::Vnet::SubnetNexus.assemble(project.id, name: "other-ps").subject)
      password = pg.superuser_password
      host = "test-pg.#{pg.ubid}.pg.ubicloud.com"
      visit "#{pg_path}/connection"

      box = ->(key) { find(".connection-info-box-#{key}") }
      expect(page).to have_css(".connection-info-box", count: 1)
      expect(box.call("url-5432")).to have_text("●●●●●●")
      expect(page).to have_no_content(password)

      # Revealing the content
      box.call("url-5432").find(".revealable-button", match: :first).click
      expect(box.call("url-5432")).to have_text("postgresql://postgres:#{password}@#{host}:5432/postgres?sslmode=require&channel_binding=require")

      # The revealed state is kept when switching formats
      find(".connection-info-format-selector select").select("psql")
      expect(page).to have_css(".connection-info-box", count: 1)
      expect(box.call("psql-5432")).to have_text("psql 'postgresql://postgres:#{password}@#{host}:5432/postgres")

      check "Use pgBouncer?"
      expect(page).to have_css(".connection-info-box", count: 1)
      expect(box.call("psql-6432")).to have_text("psql 'postgresql://postgres:#{password}@#{host}:6432/postgres")

      check "Use Private DNS?"
      expect(page).to have_css(".connection-info-box", count: 1)
      expect(box.call("psql-6432-private")).to have_text("psql 'postgresql://postgres:#{password}@private.#{host}:6432/postgres")

      # Hiding the content
      box.call("psql-6432-private").find(".revealed-content .revealable-button").click
      expect(box.call("psql-6432-private")).to have_text("●●●●●●")
      expect(page).to have_no_content(password)

      # The hidden state is kept when switching formats
      find(".connection-info-format-selector select").select("env")
      uncheck "Use pgBouncer?"
      uncheck "Use Private DNS?"
      expect(page).to have_css(".connection-info-box", count: 1)
      expect(box.call("env-5432")).to have_text("●●●●●●")
      box.call("env-5432").find(".revealable-button", match: :first).click
      expect(box.call("env-5432")).to have_text("PGHOST=#{host}")

      # Copying shows a notification, which is removed after 2 seconds
      box.call("env-5432").find(".copy-button").click
      expect(page).to have_css("#notification-template + div p", exact_text: "Copied")
      expect(page).to have_no_css("#notification-template + div", wait: 4)
    end

    it "picks the restore target using the date picker and the backup fork icons" do
      latest = Time.utc(2026, 7, 13, 12, 30)
      earliest = Time.utc(2026, 7, 3, 12, 30)
      backup_time = Time.utc(2026, 7, 10, 4, 29, 10)
      allow_any_instance_of(PostgresResource).to receive(:backup_download_unavailable_message).and_return("unavailable")
      allow_any_instance_of(PostgresTimeline).to receive_messages(
        earliest_restore_time: earliest,
        latest_restore_time: latest,
        backups: [Struct.new(:last_modified).new(backup_time)],
      )
      visit "#{pg_path}/backup-restore"

      # The date picker hides the original input, and shows an alternative
      # input with the selected time (defaulting to the latest restore time)
      # in a human readable format.
      expect(page).to have_no_field("restore_target")
      alt_input = find("input.datepicker.form-control")
      expect(alt_input.value).to eq "July 13, 2026 12:30 UTC"
      expect(find_by_id("restore_target", visible: :hidden).value).to eq "2026-07-13 12:30"

      alt_input.click
      within(".flatpickr-calendar.open") do
        expect(page).to have_css(".flatpickr-day.selected", exact_text: "13")
        # Days outside the restore window cannot be selected
        expect(page).to have_css(".flatpickr-day.flatpickr-disabled[aria-label='July 2, 2026']")
        expect(page).to have_css(".flatpickr-day.flatpickr-disabled[aria-label='July 14, 2026']")
        find(".flatpickr-day[aria-label='July 5, 2026']").click
      end
      expect(alt_input.value).to eq "July 5, 2026 12:30 UTC"
      expect(find_by_id("restore_target", visible: :hidden).value).to eq "2026-07-05 12:30"

      # Clicking the fork icon for a backup sets the restore target to the
      # backup time, rounded up to the next minute, and flashes the input.
      find(".fork-icon").click
      expect(page).to have_field("restore_target", with: "2026-07-10 04:30")
      expect(page).to have_css("#restore_target", style: {"animation-name" => "flash"})
      expect(page).to have_css("#restore_target", style: {"animation-name" => "none"}, wait: 4)

      fill_in "New server name", with: "test-pg-fork"
      click_button "Fork"
      expect_flash_notice("'test-pg-fork' will be ready in a few minutes")
      expect(PostgresResource.first(name: "test-pg-fork").restore_target).to eq Time.utc(2026, 7, 10, 4, 30)
    end

    describe "logs" do
      let(:parseable_client) { instance_double(Parseable::Client) }

      before do
        allow(ParseableResource).to receive(:client_for_project).and_return(parseable_client)
      end

      it "picks the log time range using date pickers" do
        queried_ranges = []
        allow(parseable_client).to receive(:query) do |_sql, start_time:, end_time:|
          queried_ranges << [start_time, end_time]
          (1..40).map do |i|
            {"log_id" => format("0196a9f7-0000-7000-8000-%012d", i), "time_unix_nano" => "2026-07-13T11:00:00.000", "stream" => "postgres",
             "severity_text" => "INFO", "body" => "log line #{i}", "instance" => "pv123", "server_role" => "primary"}
          end
        end
        # Log queries are limited to the last 7 days, so use times relative to now.
        now = Time.now.utc
        end_time = Time.utc(now.year, now.month, now.day, now.hour) - 60 * 60
        start_time = end_time - 30 * 60
        iso = ->(t) { t.strftime("%Y-%m-%dT%H:%M:00Z") }
        display = ->(t) { t.strftime("%B %-d, %Y %H:%M UTC") }

        visit "#{pg_path}/logs?start=#{iso.call(start_time)}&end=#{iso.call(end_time)}"
        expect(page).to have_content("log line 40")

        start_input, end_input = all("input.datepicker.form-control", count: 2)
        expect(start_input.value).to eq display.call(start_time)
        expect(end_input.value).to eq display.call(end_time)

        # Move the time range one day earlier
        day = 24 * 60 * 60
        [[start_input, start_time, "start"], [end_input, end_time, "end"]].each do |input, time, name|
          new_time = time - day
          input.click
          within(".flatpickr-calendar.open") do
            find(".flatpickr-prev-month").click if new_time.month != time.month
            find(".flatpickr-day:not(.prevMonthDay):not(.nextMonthDay)[aria-label='#{new_time.strftime("%B %-d, %Y")}']").click
          end
          expect(input.value).to eq display.call(new_time)
          expect(find("##{name}", visible: :hidden).value).to eq iso.call(new_time)
          find("h3", text: "Log Destinations").click
          expect(page).to have_no_css(".flatpickr-calendar.open")
        end

        click_button "Apply"
        expect(page).to have_current_path(/[?&]start=#{Regexp.escape(CGI.escape(iso.call(start_time - day)))}&end=#{Regexp.escape(CGI.escape(iso.call(end_time - day)))}&/)
        expect(queried_ranges.last).to eq [iso.call(start_time - day), iso.call(end_time - day)]
        expect(all("input.datepicker.form-control", count: 2).map(&:value)).to eq [display.call(start_time - day), display.call(end_time - day)]
      end

      it "adds an OTLP log destination with headers based on the selected provider" do
        allow(parseable_client).to receive(:query).and_return([])
        visit "#{pg_path}/logs"

        expect(page).to have_css("#url-prefix", exact_text: "https://")
        expect(page).to have_css("label[for=url-display]", exact_text: "OTLP Endpoint URL")
        expect(page).to have_css("#log-destination-otlp-auth")
        expect(page).to have_no_css("#log-destination-syslog-auth")
        expect(page).to have_no_css("#log-destination-otlp-auth .config-group")

        select "Datadog (US)", from: "log-destination-provider"
        expect(page).to have_field("url-display", with: "otlp.intake.datadoghq.com")
        within("#log-destination-otlp-auth") do
          expect(page).to have_css(".config-group", count: 1)
          expect(page).to have_field("header_keys[]", with: "DD-API-KEY")
        end

        # Switching providers replaces the headers
        select "OpenObserve", from: "log-destination-provider"
        expect(page).to have_field("url-display", with: "")
        within("#log-destination-otlp-auth") do
          expect(page).to have_css(".config-group", count: 2)
          expect(page).to have_field("header_keys[]", with: "Authorization")
          expect(page).to have_field("header_keys[]", with: "stream-name")
          expect(page).to have_no_field("header_keys[]", with: "DD-API-KEY")
        end

        select "Datadog (EU)", from: "log-destination-provider"
        expect(page).to have_field("url-display", with: "otlp.intake.datadoghq.eu")
        within("#log-destination-otlp-auth") do
          expect(page).to have_css(".config-group", count: 1)
          find_field("header_keys[]", with: "DD-API-KEY").ancestor(".config-entry").find_field("header_values[]").fill_in(with: "secret-key")
          within(".new-config") do
            fill_in placeholder: "New Key", with: "X-Extra"
            fill_in placeholder: "New Value", with: "extra"
            find(".add-config-btn").click
          end
          expect(page).to have_css(".config-group", count: 2)
        end

        fill_in "Name", with: "datadog"
        click_button "Add"
        expect_flash_notice("Log destination is created")
        ld = PostgresLogDestination.first(name: "datadog")
        expect(ld.type).to eq "otlp"
        expect(ld.url).to eq "https://otlp.intake.datadoghq.eu"
        expect(ld.options).to eq("headers" => {"DD-API-KEY" => "secret-key", "X-Extra" => "extra"})
      end

      it "adds a syslog log destination with structured data" do
        allow(parseable_client).to receive(:query).and_return([])
        visit "#{pg_path}/logs"

        select "Loggly", from: "log-destination-provider"
        expect(page).to have_css("#url-prefix", exact_text: "tcp://")
        expect(page).to have_css("label[for=url-display]", exact_text: "Syslog TCP Endpoint")
        expect(page).to have_field("url-display", with: "logs-01.loggly.com:6514")
        expect(page).to have_no_css("#log-destination-otlp-auth")

        within("#log-destination-syslog-auth") do
          # An SD-ID name is required to add an SD-ID group
          click_button "Add SD-ID"
          expect(page).to have_no_css(".sd-id-group")

          find(".new-sd-id-name").fill_in(with: "token@41058")
          click_button "Add SD-ID"
          expect(find(".new-sd-id-name").value).to eq ""
          find(".new-sd-id-name").fill_in(with: "other@41058")
          click_button "Add SD-ID"
          expect(page).to have_css(".sd-id-group", count: 2)

          token_group = find(".sd-id-group[data-sd-id='token@41058']")
          other_group = find(".sd-id-group[data-sd-id='other@41058']")
          expect(token_group).to have_css(".sd-id-label", exact_text: "token@41058")

          within(token_group) do
            # A key is required to add a key/value pair
            find(".add-sd-kv-btn").click
            expect(page).to have_no_css(".sd-kv-row")

            find(".new-sd-key").fill_in(with: "tag")
            find(".new-sd-value").fill_in(with: "pg")
            find(".add-sd-kv-btn").click
            expect(page).to have_css(".sd-kv-row", count: 1)
            expect(find(".new-sd-key").value).to eq ""
            expect(find(".new-sd-value").value).to eq ""

            find(".new-sd-key").fill_in(with: "removed")
            find(".new-sd-value").fill_in(with: "x")
            find(".add-sd-kv-btn").click
            expect(page).to have_css(".sd-kv-row", count: 2)
            find_field("structured_data_keys[]", with: "removed").ancestor(".sd-kv-row").find(".delete-sd-kv-btn").click
            expect(page).to have_css(".sd-kv-row", count: 1)

            # Key/value pairs that were entered but not added are added on submit
            find(".new-sd-key").fill_in(with: "token")
            find(".new-sd-value").fill_in(with: "abc123")
          end

          within(other_group) do
            find(".new-sd-key").fill_in(with: "removed")
            find(".add-sd-kv-btn").click
            click_button "Remove"
          end
          expect(page).to have_css(".sd-id-group", count: 1)
        end

        fill_in "Name", with: "loggly"
        click_button "Add"
        expect_flash_notice("Log destination is created")
        ld = PostgresLogDestination.first(name: "loggly")
        expect(ld.type).to eq "syslog"
        expect(ld.url).to eq "tcp://logs-01.loggly.com:6514"
        expect(ld.options).to eq("structured_data" => {"token@41058" => {"tag" => "pg", "token" => "abc123"}})
      end
    end

    describe "metrics charts" do
      let(:metric_queries) { Queue.new }

      before do
        queries = metric_queries
        client = Object.new
        # Constant values, so that the formatted values shown in tooltips are predictable.
        client.define_singleton_method(:query_range) do |query:, start_ts:, end_ts:|
          queries << [query, start_ts, end_ts]
          values = ->(value) { (start_ts..end_ts).step(60).map { [it, value.to_s] } }
          case query
          when /node_cpu_seconds_total/
            [{"labels" => {"mode" => "user"}, "values" => values.call(42)}]
          when /node_load1\b/
            [{"labels" => {}, "values" => values.call(0.5)}]
          when /node_network_receive_bytes_total/
            [{"labels" => {}, "values" => values.call(2.5 * 1024 * 1024)}]
          when /node_disk_reads_completed_total/
            [{"labels" => {}, "values" => values.call(1500)}]
          when /pg_database_size_bytes/
            [{"labels" => {}, "values" => values.call(3 * 1024**4)}]
          when /pg_stat_database_xact_commit/
            [{"labels" => {}, "values" => values.call(2_500_000)}]
          else
            []
          end
        end
        allow(VictoriaMetricsResource).to receive(:client_for_project).and_return(client)
      end

      def drain_metric_queries
        queries = []
        queries << metric_queries.pop until metric_queries.empty?
        queries
      end

      # Each chart refresh queries every series of every chart.
      def wait_for_metric_queries(count)
        queries = []
        deadline = Time.now + 5
        while queries.size < count && Time.now < deadline
          if (q = metric_queries.pop(timeout: 0.1))
            queries << q
          end
        end
        # Check that no additional queries are made
        sleep 0.5
        queries.concat(drain_metric_queries)
        expect(queries.size).to eq count
        queries
      end

      def query_window(queries)
        windows = queries.map { |_, start_ts, end_ts| end_ts - start_ts }.uniq
        expect(windows.size).to eq 1
        windows.first
      end

      def chart_tooltip(key)
        find("##{key}-chart").hover
        find("##{key}-chart div", text: /●/, match: :first)
      end

      it "renders charts with formatted tooltips, and supports changing the time range and refreshing" do
        visit "#{pg_path}/charts"
        expect(page).to have_css("#cpu_usage-chart canvas")
        expect(page).to have_css(".metric-chart canvas", count: Metrics::POSTGRES_METRICS.size)
        num_queries = Metrics::POSTGRES_METRICS.sum { |_, m| m.series.size }
        expect(query_window(wait_for_metric_queries(num_queries))).to be_within(2).of(60 * 60)

        tooltip = chart_tooltip("cpu_usage")
        expect(tooltip).to have_text(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\s+● user\s*42 %\z/)
        # The series marker uses the series color
        expect(tooltip).to have_css("span", text: "● user", style: {color: "rgb(37, 99, 235)"})
        expect(chart_tooltip("load_average")).to have_text(/● 1 minute\s*0\.5\s*\z/)
        expect(chart_tooltip("network_traffic")).to have_text(/● Received\s*2\.50 MiB\/s\z/)
        expect(chart_tooltip("disk_io")).to have_text(/● Reads\s*1\.50 K IOPS\z/)
        expect(chart_tooltip("database_size")).to have_text(/● Database Size\s*3\.00 TiB\z/)
        expect(chart_tooltip("transactions")).to have_text(/● Commits\s*2\.50 M count\/s\z/)

        select "Last 3 hours", from: "time-range"
        expect(query_window(wait_for_metric_queries(num_queries))).to be_within(2).of(3 * 60 * 60)

        click_button "Refresh"
        expect(query_window(wait_for_metric_queries(num_queries))).to be_within(2).of(3 * 60 * 60)
      end

      it "maximizes and restores charts" do
        visit "#{pg_path}/charts"
        card = find_by_id("cpu_usage-chart").ancestor(".metric-chart-card")
        chart_height = -> { Float(card.find(".metric-chart").style("height")["height"].delete_suffix("px")) }
        expect(card).to have_css(".maximize-icon")
        expect(card).to have_no_css(".minimize-icon")
        expect(chart_height.call).to eq 256
        expect(page).to have_css("body", style: {overflow: "visible"})

        # A maximized chart covers the whole window, and the page behind it does not scroll
        card.find(".maximize-chart-button").click
        expect(page).to have_css(".chart-maximized")
        expect(card).to match_style(position: "fixed", top: "0px", left: "0px", width: "1600px", height: "1000px")
        expect(chart_height.call).to be > 600
        expect(card).to have_no_css(".maximize-icon")
        expect(card).to have_css(".minimize-icon")
        expect(page).to have_css("body", style: {overflow: "hidden"})

        card.find(".maximize-chart-button").click
        expect(page).to have_no_css(".chart-maximized")
        expect(card).to match_style(position: "static")
        expect(chart_height.call).to eq 256
        expect(card).to have_css(".maximize-icon")
        expect(card).to have_no_css(".minimize-icon")
        expect(page).to have_css("body", style: {overflow: "visible"})

        # Escape restores a maximized chart
        card.find(".maximize-chart-button").click
        expect(page).to have_css(".chart-maximized")
        find("body").send_keys(:escape)
        expect(page).to have_no_css(".chart-maximized")
        expect(page).to have_css("body", style: {overflow: "visible"})

        # Escape does nothing if no chart is maximized
        find("body").send_keys(:escape)
        expect(page).to have_no_css(".chart-maximized")
      end

      it "zooms all charts by dragging over a chart, and resets the zoom" do
        visit "#{pg_path}/charts"
        num_queries = Metrics::POSTGRES_METRICS.sum { |_, m| m.series.size }
        expect(query_window(wait_for_metric_queries(num_queries))).to be_within(2).of(60 * 60)
        expect(page).to have_no_button("Reset zoom")

        chart = find_by_id("cpu_usage-chart")
        chart.drag_to(chart.ancestor(".metric-chart-card").find("h4"), steps: 10)
        expect(page).to have_button("Reset zoom")
        zoomed_window = query_window(wait_for_metric_queries(num_queries))
        expect(zoomed_window).to be >= 30 * 60
        expect(zoomed_window).to be < 60 * 60

        # Refreshing keeps the zoomed window
        click_button "Refresh"
        expect(query_window(wait_for_metric_queries(num_queries))).to eq zoomed_window

        click_button "Reset zoom"
        expect(page).to have_no_button("Reset zoom")
        expect(query_window(wait_for_metric_queries(num_queries))).to be_within(2).of(60 * 60)

        # Changing the time range also resets the zoom
        chart.drag_to(chart.ancestor(".metric-chart-card").find("h4"), steps: 10)
        expect(page).to have_button("Reset zoom")
        wait_for_metric_queries(num_queries)
        select "Last 6 hours", from: "time-range"
        expect(page).to have_no_button("Reset zoom")
        expect(query_window(wait_for_metric_queries(num_queries))).to be_within(2).of(6 * 60 * 60)
      end
    end
  end
end

# Don't use the project .rspec file, as that loads spec_helper, which is not
# compatible with running a real browser against a real server.
exit RSpec::Core::Runner.run(["--options", File::NULL, *ARGV])
