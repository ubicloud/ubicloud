# frozen_string_literal: true

require_relative "../spec_helper"

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
      postgres_project = Project.create_with_id(name: "default")
      allow(Config).to receive(:postgres_service_project_id).and_return(postgres_project.id)
      login(user.email)

      client = instance_double(Minio::Client, list_objects: [])
      allow(Minio::Client).to receive(:new).and_return(client)
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
    end

    describe "create" do
      it "can create new PostgreSQL database" do
        visit "#{project.path}/postgres/create?flavor=#{PostgresResource::Flavor::STANDARD}"

        expect(page.title).to eq("Ubicloud - Create PostgreSQL Database")
        name = "new-pg-db"
        fill_in "Name", with: name
        choose option: Location::HETZNER_FSN1_ID
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
        choose option: private_location.id
        choose option: "standard-2"
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
        choose option: Location::HETZNER_FSN1_ID
        choose option: "standard-60"
        choose option: PostgresResource::HaType::NONE

        click_button "Create"

        expect(page.title).to eq("Ubicloud - Create PostgreSQL Database")
        expect(page).to have_flash_error("Validation failed for following fields: storage_size")
        expect(page).to have_content("Storage size must be one of the following: 1024.0, 2048.0, 4096.0")
        expect(PostgresResource.count).to eq(0)
      end

      it "cannot create new PostgreSQL database with invalid location" do
        visit "#{project.path}/postgres/create?flavor=#{PostgresResource::Flavor::STANDARD}"
        expect(page.title).to eq("Ubicloud - Create PostgreSQL Database")
        name = "new-pg-db"
        fill_in "Name", with: name
        choose option: Location::HETZNER_FSN1_ID
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
        choose option: Location::HETZNER_FSN1_ID
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
        choose option: Location::HETZNER_FSN1_ID
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

        click_link pg.name, href: "#{project.path}#{pg.path}"

        expect(page.title).to eq("Ubicloud - #{pg.name}")
        expect(page).to have_content pg.name
        expect(page).to have_content "Waiting for host to be ready..."

        expect(Prog::Postgres::PostgresResourceNexus).to receive(:dns_zone).and_return(true)
        pg.update(root_cert_1: "root_cert_1", root_cert_2: "root_cert_2")
        page.refresh
        expect(page).to have_content "#{pg.name}.#{pg.ubid}.postgres.ubicloud.com"
        expect(page).to have_no_content "Waiting for host to be ready..."
        expect(page).to have_content "Download"
      end

      it "does not show delete or edit options without the appropriate permissions" do
        pg
        visit "#{project.path}/postgres"
        click_link pg.name, href: "#{project.path}#{pg.path}"
        expect(page.title).to eq("Ubicloud - #{pg.name}")
        expect(page.body).to include "metric-destination-password"
        expect(page.body).to include "form-pg-md-create"
        expect(page.body).not_to include "Lantern is a PostgreSQL-based vector database"
        expect(page).to have_content "Danger Zone"

        pg.this.update(flavor: PostgresResource::Flavor::LANTERN)
        backup = Struct.new(:key, :last_modified)
        restore_target = Time.now.utc
        expect(MinioCluster).to receive(:[]).and_return(instance_double(MinioCluster, url: "dummy-url", root_certs: "dummy-certs")).at_least(:once)
        expect(Minio::Client).to receive(:new).and_return(instance_double(Minio::Client, list_objects: [backup.new("basebackups_005/backup_stop_sentinel.json", restore_target - 10 * 60)])).at_least(:once)
        page.refresh
        fill_in "#{pg.name}-fork", with: "restored-server"
        fill_in "Target Time (UTC)", with: restore_target.strftime("%Y-%m-%d %H:%M"), visible: false
        click_button "Fork"
        expect(page.body).to include "metric-destination-password"
        expect(page.body).to include "form-pg-md-create"
        expect(page.body).to include "Lantern is a PostgreSQL-based vector database"
        expect(page).to have_content "Danger Zone"

        AccessControlEntry.dataset.destroy
        AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Postgres:view"])
        page.refresh
        expect(page.title).to eq("Ubicloud - restored-server")
        expect(page.body).not_to include "metric-destination-password"
        expect(page.body).not_to include "form-pg-md-create"
        expect(page.body).to include "Lantern is a PostgreSQL-based vector database"
        expect(page).to have_no_content "Danger Zone"
      end

      it "raises forbidden when does not have permissions" do
        visit "#{project_wo_permissions.path}#{pg_wo_permission.path}"

        expect(page.title).to eq("Ubicloud - Forbidden")
        expect(page.status_code).to eq(403)
        expect(page).to have_content "Forbidden"
      end

      it "raises not found when PostgreSQL database not exists" do
        visit "#{project.path}/location/eu-central-h1/postgres/08s56d4kaj94xsmrnf5v5m3mav"

        expect(page.title).to eq("Ubicloud - ResourceNotFound")
        expect(page.status_code).to eq(404)
        expect(page).to have_content "ResourceNotFound"
      end

      it "can update PostgreSQL instance size configuration" do
        expect(Project).to receive(:from_ubid).and_return(project).at_least(:once)
        expect(project).to receive(:postgres_resources_dataset).and_return(instance_double(Sequel::Dataset, first: pg)).at_least(:once)
        expect(pg.representative_server).to receive(:storage_size_gib).and_return(128).at_least(:once)

        visit "#{project.path}#{pg.path}"
        expect(page).to have_content "Configure PostgreSQL database"

        choose option: "standard-8"
        choose option: 256
        choose option: PostgresResource::HaType::ASYNC

        # We send PATCH request manually instead of just clicking to button because PATCH action triggered by JavaScript.
        # UI tests run without a JavaScript engine.
        form = find_by_id "creation-form"
        _csrf = form.find("input[name='_csrf']", visible: false).value
        size = form.find(:radio_button, "size", checked: true).value
        storage_size = form.find(:radio_button, "storage_size", checked: true).value
        ha_type = form.find(:radio_button, "ha_type", checked: true).value
        page.driver.submit :patch, form["action"], {size: size, storage_size: storage_size, ha_type: ha_type, _csrf:}

        pg.reload
        expect(pg.target_vm_size).to eq("standard-8")
        expect(pg.target_storage_size_gib).to eq(256)
        expect(pg.ha_type).to eq(PostgresResource::HaType::ASYNC)
      end

      it "handles errors during scale up/down" do
        visit "#{project.path}#{pg.path}"
        expect(page).to have_content "Configure PostgreSQL database"

        choose option: "standard-8"
        choose option: 64

        # We send PATCH request manually instead of just clicking to button because PATCH action triggered by JavaScript.
        # UI tests run without a JavaScript engine.
        form = find_by_id "creation-form"
        _csrf = form.find("input[name='_csrf']", visible: false).value
        size = form.find(:radio_button, "size", checked: true).value
        storage_size = form.find(:radio_button, "storage_size", checked: true).value
        page.driver.submit :patch, form["action"], {size: size, storage_size: storage_size, _csrf:}

        # Normally we follow the redirect through javascript handler. Here, we are simulating that by reloading the page.
        visit "#{project.path}#{pg.path}"
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

        visit "#{project.path}#{pg.path}"
        expect(page).to have_content "Fork PostgreSQL database"

        fill_in "#{pg.name}-fork", with: "restored-server"
        fill_in "Target Time (UTC)", with: restore_target.strftime("%Y-%m-%d %H:%M"), visible: false

        click_button "Fork"

        expect(page.status_code).to eq(200)
        expect(page.title).to eq("Ubicloud - restored-server")
      end

      it "can create a read replica of a PostgreSQL database" do
        visit "#{project.path}#{pg.path}"
        expect(page).to have_content "Read Replicas"

        fill_in "#{pg.name}-read-replica", with: "my-read-replica"

        find(".pg-read-replica-create-btn").click

        expect(page.status_code).to eq(200)
        expect(page.title).to eq("Ubicloud - my-read-replica")

        visit "#{project.path}#{pg.path}"
        expect(page).to have_content("my-read-replica")

        visit "#{project.path}/postgres"
        expect(page).to have_content("my-read-replica")
      end

      it "can promote a read replica" do
        visit "#{project.path}#{pg.path}"
        expect(page).to have_content "Read Replicas"

        fill_in "#{pg.name}-read-replica", with: "my-read-replica"

        find(".pg-read-replica-create-btn").click

        expect(page.status_code).to eq(200)
        expect(page.title).to eq("Ubicloud - my-read-replica")

        find(".promote-btn").click
        expect(PostgresResource[name: "my-read-replica"].semaphores.count).to eq(1)
        expect(page).to have_content "'my-read-replica' will be promoted in a few minutes, please refresh the page"
      end

      it "fails to promote if not a read replica" do
        visit "#{project.path}#{pg.path}"
        expect(page).to have_content "Read Replicas"

        fill_in "#{pg.name}-read-replica", with: "my-read-replica"

        find(".pg-read-replica-create-btn").click

        expect(page.status_code).to eq(200)
        expect(page.title).to eq("Ubicloud - my-read-replica")
        PostgresResource[name: "my-read-replica"].update(parent_id: nil)
        find(".promote-btn").click
        expect(page.status_code).to eq(400)
        expect(page).to have_flash_error("Non read replica servers cannot be promoted.")
      end

      it "can reset superuser password of PostgreSQL database" do
        visit "#{project.path}#{pg.path}"
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

      it "does not show reset superuser password for restoring database" do
        pg.representative_server.update(timeline_access: "fetch")

        visit "#{project.path}#{pg.path}"
        expect(page).to have_no_content "Reset superuser password"
        expect(page.status_code).to eq(200)
      end

      it "cannot reset superuser password of restoring database" do
        visit "#{project.path}#{pg.path}"
        expect(page).to have_content "Reset superuser password"

        pg.representative_server.update(timeline_access: "fetch")
        find(".reset-superuser-password-new-password").set("DummyPassword123")
        find(".reset-superuser-password-new-password-repeat").set("DummyPassword123")
        click_button "Reset"

        expect(page.status_code).to eq(400)
        expect(page).to have_flash_error("Superuser password cannot be updated during restore!")
      end

      it "can restart PostgreSQL database" do
        visit "#{project.path}#{pg.path}"
        expect(page).to have_content "Restart"
        click_button "Restart"

        expect(page.status_code).to eq(200)
      end
    end

    describe "firewall" do
      it "can show default firewall rules" do
        pg
        visit "#{project.path}#{pg.path}"

        expect(page).to have_content "Firewall Rules"
        expect(page).to have_content "0.0.0.0/0"
        expect(page).to have_content "5432"
      end

      it "can delete firewall rules" do
        pg
        visit "#{project.path}#{pg.path}"

        btn = find "#fwr-delete-#{pg.firewall_rules.first.ubid} .delete-btn"
        page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}

        expect(SemSnap.new(pg.id).set?("update_firewall_rules")).to be true
      end

      it "can not delete firewall rules when does not have permissions" do
        AccessControlEntry.create_with_id(project_id: project_wo_permissions.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Postgres:view"])

        visit "#{project_wo_permissions.path}#{pg_wo_permission.path}"
        expect(page.title).to eq "Ubicloud - pg-without-permission"

        expect { find "#fwr-delete-#{pg.firewall_rules.first.ubid} .delete-btn" }.to raise_error Capybara::ElementNotFound
      end

      it "does not show create firewall rule when does not have permissions" do
        AccessControlEntry.create_with_id(project_id: project_wo_permissions.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Postgres:view"])

        visit "#{project_wo_permissions.path}#{pg_wo_permission.path}"
        expect(page.title).to eq "Ubicloud - pg-without-permission"

        expect { find_by_id "fwr-create" }.to raise_error Capybara::ElementNotFound
      end

      it "can create firewall rule" do
        pg
        visit "#{project.path}#{pg.path}"

        fill_in "cidr", with: "1.1.1.2"
        find(".firewall-rule-create-button").click
        expect(page).to have_content "Firewall rule is created"
        expect(page).to have_content "1.1.1.2/32"
        expect(page).to have_content "5432"

        fill_in "cidr", with: "12.12.12.0/26"
        find(".firewall-rule-create-button").click
        expect(page).to have_content "Firewall rule is created"

        fill_in "cidr", with: "fd00::/64"
        find(".firewall-rule-create-button").click
        expect(page).to have_content "Firewall rule is created"
        expect(page.status_code).to eq(200)
        expect(page).to have_content "fd00::/64"

        expect(SemSnap.new(pg.id).set?("update_firewall_rules")).to be true
      end
    end

    describe "metric-destination" do
      it "can create metric destination" do
        pg
        visit "#{project.path}#{pg.path}"

        fill_in "url", with: "https://example.com"
        fill_in "username", with: "username"
        find(".metric-destination-password").set("password")
        find(".metric-destination-create-button").click
        expect(page).to have_content "https://example.com"
        expect(pg.reload.metric_destinations.count).to eq(1)
      end

      it "can delete metric destinations" do
        md = PostgresMetricDestination.create_with_id(
          postgres_resource_id: pg.id,
          url: "https://example.com",
          username: "username",
          password: "password"
        )
        visit "#{project.path}#{pg.path}"

        btn = find "#md-delete-#{md.ubid} .delete-btn"
        page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}

        expect(pg.reload.metric_destinations.count).to eq(0)
      end

      it "cannot delete metric destination if it is not exist" do
        md = PostgresMetricDestination.create_with_id(
          postgres_resource_id: pg.id,
          url: "https://example.com",
          username: "username",
          password: "password"
        )
        expect(PostgresMetricDestination).to receive(:from_ubid).and_return(nil)

        visit "#{project.path}#{pg.path}"

        btn = find "#md-delete-#{md.ubid} .delete-btn"
        page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}

        expect(pg.reload.metric_destinations.count).to eq(1)
      end
    end

    describe "set-maintenance-window" do
      it "sets maintenance window to nil when empty string is passed" do
        pg.update(maintenance_window_start_at: 9)
        visit "#{project.path}#{pg.path}"

        select "No Maintenance Window", from: "maintenance_window_start_at"
        click_button "Set"
        expect(pg.reload.maintenance_window_start_at).to be_nil
      end
    end

    describe "delete" do
      it "can delete PostgreSQL database" do
        visit "#{project.path}#{pg.path}"

        # We send delete request manually instead of just clicking to button because delete action triggered by JavaScript.
        # UI tests run without a JavaScript enginer.
        btn = find "#postgres-delete-#{pg.ubid} .delete-btn"
        page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}

        expect(SemSnap.new(pg.id).set?("destroy")).to be true
      end

      it "can not delete PostgreSQL database when does not have permissions" do
        # Give permission to view, so we can see the detail page
        AccessControlEntry.create_with_id(project_id: project_wo_permissions.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Postgres:view"])

        visit "#{project_wo_permissions.path}#{pg_wo_permission.path}"
        expect(page.title).to eq "Ubicloud - pg-without-permission"

        expect { find ".delete-btn" }.to raise_error Capybara::ElementNotFound
      end
    end
  end
end
