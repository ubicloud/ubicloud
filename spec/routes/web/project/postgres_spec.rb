# frozen_string_literal: true

require_relative "../spec_helper"
require "aws-sdk-s3"

RSpec.describe Clover, "postgres" do
  let(:user) { create_account }
  let(:project) { user.create_project_with_default_policy("project-1") }
  let(:project_wo_permissions) { user.create_project_with_default_policy("project-2", default_policy: nil) }

  let(:pg) do
    Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: project.id,
      location_id: Location::HETZNER_FSN1_ID,
      name: "pg-with-permission",
      target_vm_size: "standard-2",
      target_storage_size_gib: 128
    ).subject
  end

  let(:pg_wo_permission) do
    Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: project_wo_permissions.id,
      location_id: Location::HETZNER_FSN1_ID,
      name: "pg-without-permission",
      target_vm_size: "standard-2",
      target_storage_size_gib: 128
    ).subject
  end

  describe "unauthenticated" do
    it "cannot list without login" do
      visit "/postgres"

      expect(page.title).to eq("Ubicloud - Login")
    end

    it "cannot create without login" do
      visit "/postgres/create"

      expect(page.title).to eq("Ubicloud - Login")
    end
  end

  describe "authenticated" do
    before do
      postgres_project = Project.create(name: "default")
      allow(Config).to receive(:postgres_service_project_id).and_return(postgres_project.id)
      login(user.email)

      client = instance_double(Minio::Client, list_objects: [])
      allow(Minio::Client).to receive(:new).and_return(client)

      vmc = instance_double(VictoriaMetrics::Client, query_range: [nil])
      vms = instance_double(VictoriaMetricsServer, client: vmc)
      vmr = instance_double(VictoriaMetricsResource, servers: [vms])
      allow(VictoriaMetricsResource).to receive(:first).and_return(vmr)
    end

    describe "list" do
      it "can list flavors when there is no pg databases" do
        visit "#{project.path}/postgres"

        expect(page.title).to eq("Ubicloud - PostgreSQL Databases")
        expect(page).to have_content "Create PostgreSQL Database"
        expect(page).to have_content "Create ParadeDB PostgreSQL Database"

        click_link "Create PostgreSQL Database"
        expect(page.title).to eq("Ubicloud - Create PostgreSQL Database")
      end

      it "can list only the postgres databases which has permissions to" do
        pg
        pg_wo_permission
        visit "#{project.path}/postgres"

        expect(page.title).to eq("Ubicloud - PostgreSQL Databases")
        expect(page).to have_content pg.name
        expect(page).to have_no_content pg_wo_permission.name
      end

      it "can list PostgreSQL databases with parents" do
        pg
        pg.update(parent_id: pg_wo_permission.id)
        visit "#{project.path}/postgres"

        expect(page).to have_content pg_wo_permission.name
      end
    end

    describe "create" do
      it "can create new PostgreSQL database" do
        visit "#{project.path}/postgres/create?flavor=#{PostgresResource::Flavor::STANDARD}"

        expect(page.title).to eq("Ubicloud - Create PostgreSQL Database")
        name = "new-pg-db"
        fill_in "Name", with: name
        choose option: Location::HETZNER_FSN1_UBID
        choose option: "standard-2"
        choose option: PostgresResource::HaType::NONE

        click_button "Create"

        expect(page.title).to eq("Ubicloud - #{name}")
        expect(page).to have_flash_notice("'#{name}' will be ready in a few minutes")
        expect(PostgresResource.count).to eq(1)
        expect(PostgresResource.first.project_id).to eq(project.id)
      end

      it "can create new PostgreSQL database in a custom AWS region" do
        project
        private_location = create_private_location(project: project)
        Location.where(id: [Location::HETZNER_FSN1_ID, Location::LEASEWEB_WDC02_ID]).destroy

        visit "#{project.path}/postgres/create?flavor=#{PostgresResource::Flavor::STANDARD}"

        expect(page.title).to eq("Ubicloud - Create PostgreSQL Database")
        name = "new-pg-db"
        fill_in "Name", with: name
        choose option: private_location.ubid
        choose option: "m6id.large"
        choose option: PostgresResource::HaType::NONE
        choose option: "118"

        click_button "Create"

        expect(page.title).to eq("Ubicloud - #{name}")
        expect(page).to have_flash_notice("'#{name}' will be ready in a few minutes")
        expect(PostgresResource.count).to eq(1)
        pg = PostgresResource.first
        expect(pg.project_id).to eq(project.id)
        expect(pg.target_storage_size_gib).to eq(118)
      end

      it "handles errors when creating new PostgreSQL database" do
        visit "#{project.path}/postgres/create?flavor=#{PostgresResource::Flavor::STANDARD}"

        expect(page.title).to eq("Ubicloud - Create PostgreSQL Database")
        name = "new-pg-db"
        fill_in "Name", with: name
        choose option: Location::HETZNER_FSN1_UBID
        choose option: "standard-60"
        choose option: PostgresResource::HaType::NONE

        click_button "Create"

        expect(page.title).to eq("Ubicloud - Create PostgreSQL Database")
        expect(page).to have_flash_error("Validation failed for following fields: storage_size")
        expect(page).to have_content("Invalid storage size. Available options: 1024, 2048, 4096")
        expect(PostgresResource.count).to eq(0)
      end

      it "cannot create new PostgreSQL database with invalid location" do
        visit "#{project.path}/postgres/create?flavor=#{PostgresResource::Flavor::STANDARD}"
        expect(page.title).to eq("Ubicloud - Create PostgreSQL Database")
        name = "new-pg-db"
        fill_in "Name", with: name
        choose option: Location::HETZNER_FSN1_UBID
        choose option: "standard-60"
        choose option: PostgresResource::HaType::NONE
        Location[Location::HETZNER_FSN1_ID].destroy

        click_button "Create"
        expect(page.title).to eq("Ubicloud - ResourceNotFound")
        expect(page.status_code).to eq(404)
        expect(page).to have_content "ResourceNotFound"
      end

      it "can create new ParadeDB PostgreSQL database" do
        expect(Config).to receive(:postgres_paradedb_notification_email).and_return("dummy@mail.com")
        expect(Util).to receive(:send_email)
        visit "#{project.path}/postgres/create?flavor=#{PostgresResource::Flavor::PARADEDB}"

        expect(page.title).to eq("Ubicloud - Create ParadeDB PostgreSQL Database")
        name = "new-pg-db"
        fill_in "Name", with: name
        choose option: Location::HETZNER_FSN1_UBID
        choose option: "standard-2"
        choose option: PostgresResource::HaType::NONE
        check "Accept Terms of Service and Privacy Policy"

        click_button "Create"

        expect(page.title).to eq("Ubicloud - #{name}")
        expect(page).to have_flash_notice("'#{name}' will be ready in a few minutes")
        expect(PostgresResource.count).to eq(1)
        expect(PostgresResource.first.project_id).to eq(project.id)
      end

      it "can create new Lantern PostgreSQL database when the feature flag is enabled" do
        project.set_ff_postgres_lantern(true)
        visit "#{project.path}/postgres/create?flavor=#{PostgresResource::Flavor::LANTERN}"

        expect(page.title).to eq("Ubicloud - Create Lantern PostgreSQL Database")
        name = "new-pg-db"
        fill_in "Name", with: name
        choose option: Location::HETZNER_FSN1_UBID
        choose option: "standard-2"
        choose option: PostgresResource::HaType::NONE
        check "Accept Terms of Service and Privacy Policy"

        click_button "Create"
        expect(page.title).to eq("Ubicloud - #{name}")
        expect(page).to have_flash_notice("'#{name}' will be ready in a few minutes")
        expect(PostgresResource.count).to eq(1)
        expect(PostgresResource.first.project_id).to eq(project.id)
      end

      it "can not create new ParadeDB PostgreSQL database in a customer specific location" do
        project
        private_location = create_private_location(project: project)

        visit "#{project.path}/postgres/create?flavor=#{PostgresResource::Flavor::PARADEDB}"

        expect(page.title).to eq("Ubicloud - Create ParadeDB PostgreSQL Database")
        expect(page).to have_no_content private_location.name
      end

      it "can not open create page with invalid flavor" do
        default_project = Project[name: "Default"]
        url = "#{default_project.path}/dashboard"
        Capybara.current_session.driver.header "Referer", url
        visit "#{project.path}/postgres/create?flavor=invalid"

        expect(page.title).to eq("Ubicloud - Default Dashboard")
      end

      it "can not create PostgreSQL database with same name" do
        visit "#{project.path}/postgres/create"

        expect(page.title).to eq("Ubicloud - Create PostgreSQL Database")

        fill_in "Name", with: pg.name
        choose option: Location::HETZNER_FSN1_UBID
        choose option: "standard-2"
        choose option: PostgresResource::HaType::NONE

        click_button "Create"

        expect(page.title).to eq("Ubicloud - Create PostgreSQL Database")
        expect(page).to have_flash_error("project_id and location_id and name is already taken")
      end

      it "can not select invisible location" do
        visit "#{project.path}/postgres/create"

        expect(page.title).to eq("Ubicloud - Create PostgreSQL Database")

        expect { choose option: "github-runners" }.to raise_error Capybara::ElementNotFound
      end

      it "can not create PostgreSQL database in a project when does not have permissions" do
        project_wo_permissions
        visit "#{project_wo_permissions.path}/postgres/create"

        expect(page.title).to eq("Ubicloud - Forbidden")
        expect(page.status_code).to eq(403)
        expect(page).to have_content "Forbidden"
      end

      it "cannot create when location not exist" do
        visit "#{project.path}/location/not-exist-location/postgres/create"

        expect(page.title).to eq("Ubicloud - ResourceNotFound")
        expect(page.status_code).to eq(404)
        expect(page).to have_content "ResourceNotFound"
      end
    end

    describe "show" do
      it "can show PostgreSQL database details" do
        pg
        visit "#{project.path}/postgres"

        expect(page.title).to eq("Ubicloud - PostgreSQL Databases")
        expect(page).to have_content pg.name

        click_link pg.name, href: "#{project.path}#{pg.path}/overview"

        expect(page.title).to eq("Ubicloud - #{pg.name}")
        expect(page).to have_content pg.name
      end

      it "can show PostgreSQL database details even when no subpage is specified" do
        pg
        visit "#{project.path}#{pg.path}"

        expect(page.title).to eq("Ubicloud - #{pg.name}")
        expect(page).to have_content pg.name
      end

      it "can show disk usage details" do
        pg
        pg.representative_server.vm.add_vm_storage_volume(boot: false, size_gib: 128, disk_index: 0)

        vmc = instance_double(VictoriaMetrics::Client, query_range: [{"values" => [[Time.now.utc.to_i, "50"]]}])
        vms = instance_double(VictoriaMetricsServer, client: vmc)
        vmr = instance_double(VictoriaMetricsResource, servers: [vms])
        expect(VictoriaMetricsResource).to receive(:first).and_return(vmr)

        visit "#{project.path}#{pg.path}/overview"
        expect(page).to have_content "64.0 GB is used (50.0%)"
      end

      it "shows the disk usage in red if usage is high" do
        pg
        pg.representative_server.vm.add_vm_storage_volume(boot: false, size_gib: 128, disk_index: 0)

        vmc = instance_double(VictoriaMetrics::Client, query_range: [{"values" => [[Time.now.utc.to_i, "90"]]}])
        vms = instance_double(VictoriaMetricsServer, client: vmc)
        vmr = instance_double(VictoriaMetricsResource, servers: [vms])
        expect(VictoriaMetricsResource).to receive(:first).and_return(vmr)

        visit "#{project.path}#{pg.path}/overview"
        expect(page).to have_css("span.text-red-600", text: "115.2 GB is used (90.0%)")
      end

      it "shows total disk if there is no VictoriaMetricsResource" do
        pg
        pg.representative_server.vm.add_vm_storage_volume(boot: false, size_gib: 128, disk_index: 0)

        expect(VictoriaMetricsResource).to receive(:first).and_return(nil)

        visit "#{project.path}#{pg.path}/overview"
        expect(page).to have_content "128 GB"
      end

      it "shows AZ id for AWS PostgreSQL instance" do
        AwsInstance.create_with_id(pg.representative_server.vm.id, instance_id: "i-0123456789abcdefg", az_id: "usw2-az2")

        visit "#{project.path}#{pg.path}/overview"
        expect(page).to have_content "usw2-az2 (AWS)"
      end

      it "shows total disk if VictoriaMetricsResource is not accessible" do
        pg
        pg.representative_server.vm.add_vm_storage_volume(boot: false, size_gib: 128, disk_index: 0)

        vmc = instance_double(VictoriaMetrics::Client)
        expect(vmc).to receive(:query_range).and_raise(Excon::Error::Socket)
        vms = instance_double(VictoriaMetricsServer, client: vmc)
        vmr = instance_double(VictoriaMetricsResource, servers: [vms])
        expect(VictoriaMetricsResource).to receive(:first).and_return(vmr)

        visit "#{project.path}#{pg.path}/overview"
        expect(page).to have_content "128 GB"
      end

      it "can show basic metrics on overview page" do
        pg.strand.update(label: "wait")
        visit "#{project.path}#{pg.path}/overview"
        expect(page).to have_css(".metric-chart")
      end

      it "shows connections if the resource is running" do
        pg.strand.update(label: "wait")
        visit "#{project.path}#{pg.path}/connection"
        expect(page).to have_no_content "No connection information available"
      end

      it "does not show connections if the resource is creating" do
        pg.strand.update(label: "wait_servers")
        visit "#{project.path}#{pg.path}/connection"
        expect(page).to have_content "No connection information available"
      end

      it "shows 404 for invalid pages for read replicas" do
        pg
        pg.update(parent_id: pg_wo_permission.id)
        visit "#{project.path}#{pg.path}/resize"

        expect(page.title).to eq("Ubicloud - ResourceNotFound")
        expect(page.status_code).to eq(404)
      end

      it "does not show delete or edit options without the appropriate permissions" do
        pg
        pg.timeline.update(cached_earliest_backup_at: Time.now.utc)

        visit "#{project.path}#{pg.path}/networking"
        expect(page).to have_css(".firewall-rule-create-button")

        visit "#{project.path}#{pg.path}/read-replica"
        expect(page).to have_css(".pg-read-replica-create-btn")

        visit "#{project.path}#{pg.path}/settings"
        expect(page).to have_content "Danger Zone"

        AccessControlEntry.dataset.destroy
        AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Postgres:view"])

        visit "#{project.path}#{pg.path}/networking"
        expect(page).to have_no_css(".firewall-rule-create-button")

        visit "#{project.path}#{pg.path}/read-replica"
        expect(page).to have_no_css(".pg-read-replica-create-btn")

        visit "#{project.path}#{pg.path}/settings"
        expect(page).to have_no_content "Danger Zone"
      end

      it "raises forbidden when does not have permissions" do
        visit "#{project_wo_permissions.path}#{pg_wo_permission.path}/overview"

        expect(page.title).to eq("Ubicloud - Forbidden")
        expect(page.status_code).to eq(403)
        expect(page).to have_content "Forbidden"
      end

      it "raises not found when PostgreSQL database not exists" do
        visit "#{project.path}/location/eu-central-h1/postgres/08s56d4kaj94xsmrnf5v5m3mav/overview"

        expect(page.title).to eq("Ubicloud - ResourceNotFound")
        expect(page.status_code).to eq(404)
        expect(page).to have_content "ResourceNotFound"
      end

      it "can update PostgreSQL instance size configuration" do
        pg.representative_server.vm.add_vm_storage_volume(boot: false, size_gib: 128, disk_index: 0)

        visit "#{project.path}#{pg.path}/resize"

        choose option: "standard-8"
        choose option: 256

        # We send PATCH request manually instead of just clicking to button because PATCH action triggered by JavaScript.
        # UI tests run without a JavaScript engine.
        form = find_by_id "creation-form"
        _csrf = form.find("input[name='_csrf']", visible: false).value
        size = form.find(:radio_button, "size", checked: true).value
        storage_size = form.find(:radio_button, "storage_size", checked: true).value
        page.driver.submit :patch, form["action"], {size:, storage_size:, _csrf:}

        pg.reload
        expect(pg.target_vm_size).to eq("standard-8")
        expect(pg.target_storage_size_gib).to eq(256)
      end

      it "handles errors during scale up/down" do
        visit "#{project.path}#{pg.path}/resize"

        choose option: "standard-8"
        choose option: 64

        # We send PATCH request manually instead of just clicking to button because PATCH action triggered by JavaScript.
        # UI tests run without a JavaScript engine.
        form = find_by_id "creation-form"
        _csrf = form.find("input[name='_csrf']", visible: false).value
        size = form.find(:radio_button, "size", checked: true).value
        storage_size = form.find(:radio_button, "storage_size", checked: true).value
        page.driver.submit :patch, form["action"], {size:, storage_size:, _csrf:}

        # Normally we follow the redirect through javascript handler. Here, we are simulating that by reloading the page.
        visit "#{project.path}#{pg.path}/resize"
        expect(page).to have_flash_error "Validation failed for following fields: storage_size"

        pg.reload
        expect(pg.target_vm_size).to eq("standard-2")
        expect(pg.target_storage_size_gib).to eq(128)
      end

      it "can restore PostgreSQL database" do
        backup = Struct.new(:key, :last_modified)
        restore_target = Time.now.utc
        expect(MinioCluster).to receive(:[]).and_return(instance_double(MinioCluster, url: "dummy-url", root_certs: "dummy-certs")).at_least(:once)
        expect(Minio::Client).to receive(:new).and_return(instance_double(Minio::Client, list_objects: [backup.new("basebackups_005/backup_stop_sentinel.json", restore_target - 10 * 60)])).at_least(:once)

        visit "#{project.path}#{pg.path}/backup-restore"
        expect(page).to have_content "Fork PostgreSQL database"

        fill_in "#{pg.name}-fork", with: "restored-server"
        fill_in "Target Time (UTC)", with: restore_target.strftime("%Y-%m-%d %H:%M"), visible: false

        click_button "Fork"

        expect(page.status_code).to eq(200)
        expect(page.title).to eq("Ubicloud - restored-server")
      end

      it "shows proper message when there is no backups to restore" do
        expect(MinioCluster).to receive(:[]).and_return(instance_double(MinioCluster, url: "dummy-url", root_certs: "dummy-certs")).at_least(:once)
        expect(Minio::Client).to receive(:new).and_return(instance_double(Minio::Client, list_objects: [])).at_least(:once)

        visit "#{project.path}#{pg.path}/backup-restore"
        expect(page).to have_content "No backups available for this PostgreSQL database."
      end

      it "can create a read replica of a PostgreSQL database" do
        pg.timeline.update(cached_earliest_backup_at: Time.now.utc)
        visit "#{project.path}#{pg.path}/read-replica"

        fill_in "#{pg.name}-read-replica", with: "my-read-replica"

        find(".pg-read-replica-create-btn").click

        expect(page.status_code).to eq(200)
        expect(page.title).to eq("Ubicloud - my-read-replica")

        visit "#{project.path}#{pg.path}/read-replica"
        expect(page).to have_content("my-read-replica")
      end

      it "cannot create a read replica if there is no backup, yet" do
        pg.timeline.update(cached_earliest_backup_at: Time.now.utc)
        visit "#{project.path}#{pg.path}/read-replica"
        pg.timeline.update(cached_earliest_backup_at: nil)

        fill_in "#{pg.name}-read-replica", with: "my-read-replica"

        find(".pg-read-replica-create-btn").click

        expect(page.status_code).to eq(400)
        expect(page).to have_content("Parent server is not ready for read replicas. There are no backups, yet.")
      end

      it "can promote a read replica" do
        pg.timeline.update(cached_earliest_backup_at: Time.now.utc)
        visit "#{project.path}#{pg.path}/read-replica"

        fill_in "#{pg.name}-read-replica", with: "my-read-replica"

        find(".pg-read-replica-create-btn").click

        expect(page.status_code).to eq(200)
        expect(page.title).to eq("Ubicloud - my-read-replica")

        visit "#{project.path}#{pg.read_replicas.first.path}/settings"
        find(".promote-btn").click
        expect(PostgresResource[name: "my-read-replica"].semaphores.count).to eq(1)
        expect(page).to have_content "'my-read-replica' will be promoted in a few minutes, please refresh the page"
      end

      it "fails to promote if not a read replica" do
        pg.timeline.update(cached_earliest_backup_at: Time.now.utc)
        visit "#{project.path}#{pg.path}/read-replica"
        expect(page).to have_content "Read Replicas"

        fill_in "#{pg.name}-read-replica", with: "my-read-replica"

        find(".pg-read-replica-create-btn").click

        expect(page.status_code).to eq(200)
        expect(page.title).to eq("Ubicloud - my-read-replica")

        pg_read_replica = PostgresResource[name: "my-read-replica"]
        visit "#{project.path}#{pg_read_replica.path}/settings"
        PostgresResource[name: "my-read-replica"].update(parent_id: nil)
        find(".promote-btn").click
        expect(page.status_code).to eq(400)
        expect(page).to have_flash_error("Non read replica servers cannot be promoted.")
      end

      it "can reset superuser password of PostgreSQL database" do
        visit "#{project.path}#{pg.path}/settings"
        expect(page.title).to eq "Ubicloud - pg-with-permission"
        expect(page).to have_content "Reset superuser password"
        password = pg.superuser_password

        find(".reset-superuser-password-new-password").set("Dummy")
        find(".reset-superuser-password-new-password-repeat").set("DummyPassword123")
        click_button "Reset"
        expect(page).to have_flash_error "Validation failed for following fields: password, repeat_password"
        expect(find_by_id("password-error").text).to eq "Password must have 12 characters minimum. Password must have at least one digit."
        expect(find_by_id("repeat_password-error").text).to eq "Passwords must match."

        expect(pg.reload.superuser_password).to eq password

        find(".reset-superuser-password-new-password").set("DummyPassword123")
        find(".reset-superuser-password-new-password-repeat").set("DummyPassword123")
        click_button "Reset"

        expect(page).to have_flash_notice "The superuser password will be updated in a few seconds"
        expect(pg.reload.superuser_password).to eq("DummyPassword123")
        expect(page.status_code).to eq(200)
      end

      it "can restart PostgreSQL database" do
        visit "#{project.path}#{pg.path}/settings"
        expect(page).to have_content "Restart"
        click_button "Restart"

        expect(page.status_code).to eq(200)
      end

      it "doesn't show reset button when does not have permissions" do
        # Give permission to view, so we can see the detail page
        AccessControlEntry.create(project_id: project_wo_permissions.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Postgres:view"])
        AccessControlEntry.create(project_id: project_wo_permissions.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Postgres:delete"])

        visit "#{project_wo_permissions.path}#{pg_wo_permission.path}/settings"
        expect(page.title).to eq "Ubicloud - pg-without-permission"

        expect { find ".restart-btn" }.to raise_error Capybara::ElementNotFound
      end

      it "shows metrics if the resource is not creating" do
        pg.strand.update(label: "wait")
        visit "#{project.path}#{pg.path}/charts"
        expect(page).to have_content "CPU Usage"
      end

      it "does not show metrics the resource is creating" do
        pg.strand.update(label: "wait_servers")
        visit "#{project.path}#{pg.path}/charts"
        expect(page).to have_no_content "CPU Usage"
      end
    end

    describe "firewall" do
      it "can show default firewall rules" do
        pg
        visit "#{project.path}#{pg.path}/networking"

        expect(page).to have_content "Firewall Rules"
        expect(page).to have_content "0.0.0.0/0"
        expect(page).to have_content "5432"
      end

      it "can delete firewall rules" do
        pg
        visit "#{project.path}#{pg.path}/networking"

        btn = find "#fwr-buttons-#{pg.firewall_rules.first.ubid} .delete-btn"
        page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}

        expect(SemSnap.new(pg.id).set?("update_firewall_rules")).to be true
      end

      it "can not delete firewall rules when does not have permissions" do
        AccessControlEntry.create(project_id: project_wo_permissions.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Postgres:view"])

        visit "#{project_wo_permissions.path}#{pg_wo_permission.path}/networking"
        expect(page.title).to eq "Ubicloud - pg-without-permission"

        expect { find "#fwr-buttons-#{pg.firewall_rules.first.ubid} .delete-btn" }.to raise_error Capybara::ElementNotFound
      end

      it "does not show create firewall rule when does not have permissions" do
        AccessControlEntry.create(project_id: project_wo_permissions.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Postgres:view"])

        visit "#{project_wo_permissions.path}#{pg_wo_permission.path}/networking"
        expect(page.title).to eq "Ubicloud - pg-without-permission"

        expect { find_by_id "fwr-create" }.to raise_error Capybara::ElementNotFound
      end

      it "can create firewall rule" do
        pg
        visit "#{project.path}#{pg.path}/networking"

        find('input[name="cidr"][form="form-pg-fwr-create"]').set("1.1.1.2")
        find(".firewall-rule-create-button").click
        expect(page).to have_content "Firewall rule is created"
        expect(page).to have_content "1.1.1.2/32"
        expect(page).to have_content "5432"

        find('input[name="cidr"][form="form-pg-fwr-create"]').set("12.12.12.0/26")
        find(".firewall-rule-create-button").click
        expect(page).to have_content "Firewall rule is created"

        find('input[name="cidr"][form="form-pg-fwr-create"]').set("fd00::/64")
        find('input[name="description"][form="form-pg-fwr-create"]').set("test description - new firewall rule")
        find(".firewall-rule-create-button").click
        expect(page).to have_content "Firewall rule is created"
        expect(page.status_code).to eq(200)
        expect(page).to have_content "fd00::/64"
        expect(page).to have_content "test description - new firewall rule"

        expect(SemSnap.new(pg.id).set?("update_firewall_rules")).to be true
      end

      it "can update firewall rule" do
        pg
        visit "#{project.path}#{pg.path}/networking"

        btn = find "#fwr-buttons-#{pg.firewall_rules.first.ubid} .save-inline-btn"
        url = btn["data-url"]
        _csrf = btn["data-csrf"]
        page.driver.submit :patch, url, {cidr: "0.0.0.0/1", description: "dummy-description", _csrf:}

        expect(SemSnap.new(pg.id).set?("update_firewall_rules")).to be true
      end

      it "can set nil description for firewall rule" do
        pg
        visit "#{project.path}#{pg.path}/networking"

        btn = find "#fwr-buttons-#{pg.firewall_rules.first.ubid} .save-inline-btn"
        url = btn["data-url"]
        _csrf = btn["data-csrf"]
        page.driver.submit :patch, url, {cidr: "0.0.0.0/1", description: nil, _csrf:}

        expect(SemSnap.new(pg.id).set?("update_firewall_rules")).to be true
      end

      it "doesn't increment update_firewall_rules semaphore if cidr is same" do
        pg
        visit "#{project.path}#{pg.path}/networking"

        btn = find "#fwr-buttons-#{pg.firewall_rules.first.ubid} .save-inline-btn"
        url = btn["data-url"]
        _csrf = btn["data-csrf"]
        page.driver.submit :patch, url, {cidr: "0.0.0.0/0", description: "test", _csrf:}

        expect(SemSnap.new(pg.id).set?("update_firewall_rules")).to be false
      end

      it "cannot delete firewall rule if it doesn't exist" do
        pg
        visit "#{project.path}#{pg.path}/networking"

        btn = find "#fwr-buttons-#{pg.firewall_rules.first.ubid} .save-inline-btn"
        url = btn["data-url"]
        _csrf = btn["data-csrf"]

        fwr = pg.firewall_rules.first
        fwr.update(cidr: "0.0.0.0/1", postgres_resource_id: pg_wo_permission.id)

        page.driver.submit :patch, url, {cidr: "0.0.0.0/2", description: "dummy-description", _csrf:}

        expect(SemSnap.new(pg.id).set?("update_firewall_rules")).not_to be true
      end
    end

    describe "metric-destination" do
      it "can create metric destination" do
        pg
        visit "#{project.path}#{pg.path}/charts"

        fill_in "url", with: "https://example.com"
        fill_in "username", with: "username"
        find(".metric-destination-password").set("password")
        find(".metric-destination-create-button").click
        expect(page).to have_content "https://example.com"
        expect(pg.reload.metric_destinations.count).to eq(1)
      end

      it "can delete metric destinations" do
        md = PostgresMetricDestination.create(
          postgres_resource_id: pg.id,
          url: "https://example.com",
          username: "username",
          password: "password"
        )
        visit "#{project.path}#{pg.path}/charts"

        btn = find "#md-delete-#{md.ubid} .delete-btn"
        page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}

        expect(pg.reload.metric_destinations.count).to eq(0)
      end

      it "cannot delete metric destination if it is not exist" do
        md = PostgresMetricDestination.create(
          postgres_resource_id: pg.id,
          url: "https://example.com",
          username: "username",
          password: "password"
        )

        visit "#{project.path}#{pg.path}/charts"
        md.this.update(id: PostgresMetricDestination.generate_uuid)

        btn = find "#md-delete-#{md.ubid} .delete-btn"
        page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}

        expect(pg.reload.metric_destinations.count).to eq(1)
      end
    end

    describe "set-maintenance-window" do
      it "sets maintenance window to nil when empty string is passed" do
        pg.update(maintenance_window_start_at: 9)
        visit "#{project.path}#{pg.path}/settings"

        select "No Maintenance Window", from: "maintenance_window_start_at"
        click_button "Set"
        expect(pg.reload.maintenance_window_start_at).to be_nil
      end

      it "sets maintenance window to 0 when 0 is passed" do
        pg.update(maintenance_window_start_at: 9)
        visit "#{project.path}#{pg.path}/settings"

        select "00:00 - 02:00 (UTC)", from: "maintenance_window_start_at"
        click_button "Set"
        expect(pg.reload.maintenance_window_start_at).to eq(0)
      end
    end

    describe "delete" do
      it "can delete PostgreSQL database" do
        visit "#{project.path}#{pg.path}/settings"

        # We send delete request manually instead of just clicking to button because delete action triggered by JavaScript.
        # UI tests run without a JavaScript enginer.
        btn = find "#postgres-delete-#{pg.ubid} .delete-btn"
        page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}

        expect(SemSnap.new(pg.id).set?("destroy")).to be true
      end

      it "can not delete PostgreSQL database when does not have permissions" do
        # Give permission to view, so we can see the detail page
        AccessControlEntry.create(project_id: project_wo_permissions.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Postgres:view"])
        AccessControlEntry.create(project_id: project_wo_permissions.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Postgres:edit"])

        visit "#{project_wo_permissions.path}#{pg_wo_permission.path}/settings"
        expect(page.title).to eq "Ubicloud - pg-without-permission"

        expect { find ".delete-btn" }.to raise_error Capybara::ElementNotFound
      end
    end

    describe "config" do
      it "can view configuration" do
        pg.update(user_config: {"max_connections" => "120"})
        visit "#{project.path}#{pg.path}/config"

        expect(page).to have_content "PostgreSQL Configuration"
        expect(page).to have_field "pg_config_keys[]", with: "max_connections"
        expect(page).to have_field "pg_config_values[]", with: "120"
      end

      it "does not show update button when user does not have permissions" do
        pg_wo_permission.update(user_config: {"max_connections" => "120"})
        AccessControlEntry.create(project_id: project_wo_permissions.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Postgres:view"])

        visit "#{project_wo_permissions.path}#{pg_wo_permission.path}/config"
        expect(page.title).to eq "Ubicloud - pg-without-permission"

        expect { find ".delete-config-btn" }.to raise_error Capybara::ElementNotFound
        expect { find ".save-config-btn" }.to raise_error Capybara::ElementNotFound
      end

      it "shows update button when user has permissions" do
        visit "#{project.path}#{pg.path}/config"
        expect(page).to have_button "Save"

        expect { find ".pg-config-card .delete-config-btn" }.not_to raise_error
        expect { find ".save-config-btn" }.not_to raise_error
      end

      it "can update configuration" do
        pg
        pg.update(user_config: {"max_connections" => "120"})
        visit "#{project.path}#{pg.path}/config"

        within ".pg-config-card .new-config" do
          fill_in "pg_config_keys[]", with: "max_connections"
          fill_in "pg_config_values[]", with: "240"
        end
        click_button "Save"

        expect(page).to have_field "pg_config_keys[]", with: "max_connections"
        expect(page).to have_field "pg_config_values[]", with: "240"
        expect(page).to have_flash_notice "Configuration updated successfully"
        expect(pg.reload.user_config).to eq({"max_connections" => "240"})
      end

      it "shows errors when an unknown configuration is provided" do
        pg.update(user_config: {"max_connections" => "120"})
        visit "#{project.path}#{pg.path}/config"

        within ".pg-config-card .new-config" do
          fill_in "pg_config_keys[]", with: "invalid"
          fill_in "pg_config_values[]", with: "invalid"
        end
        click_button "Save"

        expect(page).to have_content "Unknown configuration parameter"
        expect(page).to have_flash_error "Validation failed for following fields: pg_config.invalid"
        expect(pg.reload.user_config).to eq({"max_connections" => "120"})
      end

      it "shows errors when an invalid configuration is provided" do
        pg.update(user_config: {"max_connections" => "120"})
        visit "#{project.path}#{pg.path}/config"

        within ".pg-config-card .new-config" do
          fill_in "pg_config_keys[]", with: "work_mem"
          fill_in "pg_config_values[]", with: "16iB"
        end
        click_button "Save"

        expect(page).to have_flash_error "Validation failed for following fields: pg_config.work_mem"
        expect(page).to have_content "must match pattern: ^[0-9]+(kB|MB|GB|TB)?$"
        expect(pg.reload.user_config).to eq({"max_connections" => "120"})
      end
    end
  end
end
