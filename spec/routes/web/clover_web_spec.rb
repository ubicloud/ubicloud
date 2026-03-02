# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover do
  it "handles CSRF token errors" do
    visit "/login"
    find(".rodauth input[name=_csrf]", visible: false).set("")
    click_button "Sign in"

    expect(page.status_code).to eq(400)
    expect(page.title).to eq "Ubicloud - Invalid Security Token"
    expect(page).to have_content("An invalid security token was submitted, please click back, refresh, and try again.")
  end

  it "does not redirect to requested path if path is too long" do
    create_account
    visit("/a" * 2048)
    expect(page.status_code).to eq(200)
    expect(page).to have_current_path("/login", ignore_query: true)
    fill_in "Email Address", with: TEST_USER_EMAIL
    click_button "Sign in"
    fill_in "Password", with: TEST_USER_PASSWORD
    click_button "Sign in"
    expect(page.title).to end_with("Dashboard")
  end

  it "supports per-request customization by overriding ace_base_query" do
    account = create_account
    project = account.create_project_with_default_policy("project-1")
    pg = PostgresResource.create(
      name: "pg-name",
      superuser_password: "dummy-password",
      ha_type: "none",
      target_version: "17",
      location_id: Location::HETZNER_FSN1_ID,
      project_id: project.id,
      user_config: {},
      pgbouncer_user_config: {},
      target_vm_size: "standard-2",
      target_storage_size_gib: 64
    )
    action_type_id = ActionType::NAME_MAP.fetch("Postgres:view")
    action_type_ubid = UBID.from_uuidish(action_type_id).to_s

    login

    # Test that admin access is allowed even for incorrect actions
    visit "/test-no-authorization-needed/custom/#{project.ubid}/#{action_type_ubid}/#{pg.ubid}/Postgres:edit/#{pg.ubid}"
    expect(page.body).to eq("true")

    # Remove admin access
    project.subject_tags_dataset.first(name: "Admin").remove_members(account.id)

    # Test that access is allowed
    visit "/test-no-authorization-needed/custom/#{project.ubid}/#{action_type_ubid}/#{pg.ubid}/Postgres:view/#{pg.ubid}"
    expect(page.body).to eq("true")

    # Create empty action and object tags, that don't contain any entries
    action_tag = ActionTag.create(project_id: project.id, name: "Empty")
    object_tag = ObjectTag.create(project_id: project.id, name: "Empty")
    # Add an ACE that grants access to those tags. Since the tags do not
    # contain any actions/objects, by itself, this grants access to nothing.
    AccessControlEntry.create(project_id: project.id, subject_id: account.id, action_id: action_tag.id, object_id: object_tag.id)

    # Test that access is allowed based on request-specific action and object
    visit "/test-no-authorization-needed/custom/#{project.ubid}/#{action_type_ubid}/#{pg.ubid}/Postgres:view/#{pg.ubid}"
    expect(page.body).to eq("true")

    # Test that request-specific permissions require matching action
    visit "/test-no-authorization-needed/custom/#{project.ubid}/#{action_type_ubid}/#{pg.ubid}/Postgres:edit/#{pg.ubid}"
    expect(page.body).to eq("false")

    # Test that request-specific permissions require matching object
    visit "/test-no-authorization-needed/custom/#{project.ubid}/#{action_type_ubid}/#{pg.ubid}/Postgres:view/#{account.ubid}"
    expect(page.body).to eq("false")

    # Add tags containing the action and object. There are no ACEs for these tags, so
    # this allows not access by default.
    containing_action_tag = ActionTag.create(project_id: project.id, name: "Containing")
    containing_action_tag.add_action(action_type_id)
    containing_object_tag = ObjectTag.create(project_id: project.id, name: "Containing")
    containing_object_tag.add_object(pg.id)

    # Test that request-specific permissions work recursively (1 level)
    visit "/test-no-authorization-needed/custom/#{project.ubid}/#{containing_action_tag.ubid}/#{containing_object_tag.ubid}/Postgres:view/#{pg.ubid}"
    expect(page.body).to eq("true")
    visit "/test-no-authorization-needed/custom/#{project.ubid}/#{containing_action_tag.ubid}/#{containing_object_tag.ubid}/Postgres:edit/#{pg.ubid}"
    expect(page.body).to eq("false")
    visit "/test-no-authorization-needed/custom/#{project.ubid}/#{containing_action_tag.ubid}/#{containing_object_tag.ubid}/Postgres:view/#{account.ubid}"
    expect(page.body).to eq("false")

    # Test that request-specific permissions work recursively (2 levels)
    containing_action_tag2 = ActionTag.create(project_id: project.id, name: "Containing2")
    containing_action_tag2.add_action(containing_action_tag.id)
    containing_object_tag2 = ObjectTag.create(project_id: project.id, name: "Containing2")
    containing_object_tag2.add_object(containing_object_tag.id)
    visit "/test-no-authorization-needed/custom/#{project.ubid}/#{containing_action_tag2.ubid}/#{containing_object_tag2.ubid}/Postgres:view/#{pg.ubid}"
    expect(page.body).to eq("true")
    visit "/test-no-authorization-needed/custom/#{project.ubid}/#{containing_action_tag2.ubid}/#{containing_object_tag2.ubid}/Postgres:edit/#{pg.ubid}"
    expect(page.body).to eq("false")
    visit "/test-no-authorization-needed/custom/#{project.ubid}/#{containing_action_tag2.ubid}/#{containing_object_tag2.ubid}/Postgres:view/#{account.ubid}"
    expect(page.body).to eq("false")
  end

  if Config.unfrozen_test?
    it "raises error if no_authorization_needed called when not needed or already authorized" do
      create_account.create_project_with_default_policy("project-1")
      login

      visit "/test-no-authorization-needed/once"
      expect(page.status_code).to eq(200)

      visit "/test-no-authorization-needed/authorization-error"
      expect(page.status_code).to eq(403)

      multiple_re = /called no_authorization_needed when authorization already not needed: /
      missing_re = /no authorization check for /
      expect { visit "/test-no-authorization-needed/twice" }.to raise_error(RuntimeError, multiple_re)
      expect { visit "/test-no-authorization-needed/after-authorization" }.to raise_error(RuntimeError, multiple_re)
      expect { visit "/test-no-authorization-needed/never" }.to raise_error(RuntimeError, missing_re)
      expect { visit "/test-no-authorization-needed/runtime-error" }.to raise_error(RuntimeError, missing_re)
    end

    it "raises original exception and not no authorization check exception when using SHOW_ERRORS" do
      show_errors = ENV["SHOW_ERRORS"]
      ENV["SHOW_ERRORS"] = "1"
      create_account.create_project_with_default_policy("project-1")
      login
      expect { visit "/test-no-authorization-needed/runtime-error" }.to raise_error(RuntimeError, "foo")
    ensure
      ENV.delete("SHOW_ERRORS") unless show_errors
    end

    it "raises error for non-GET request without audit logging" do
      expect { post "/webhook/test-no-audit-logging/test" }.to raise_error(RuntimeError, /no audit logging for /)
    end
  end

  it "raises error for unsupported audit log action" do
    create_account.create_project_with_default_policy("project-1")
    expect { post "/webhook/test-no-audit-logging/bad" }.to raise_error(RuntimeError, "unsupported audit_log action: bad_action")
  end

  it "handles typecast errors when rendering validation failure template errors" do
    visit "/webhook/test-typecast-error-during-validation-failure"

    expect(page.title).to eq("Ubicloud - Invalid Parameter Type")
    expect(page.status_code).to eq(400)
  end

  it "handles missing handle_validation_failure_call" do
    expect(Clog).to receive(:emit).with("web error without handle_validation_failure", instance_of(Hash)).and_call_original
    expect { visit "/webhook/test-missing-handle-validation-failure" }.to raise_error(RuntimeError, /Request failure without handle_validation_failure/)
  end

  it "handles missing handle_validation_failure_call when using production default of showing error template" do
    ENV["SHOW_WEB_ERROR_PAGE"] = "1"
    expect(Clog).to receive(:emit).with("web error without handle_validation_failure", instance_of(Hash)).and_call_original
    visit "/webhook/test-missing-handle-validation-failure"
    expect(page.title).to eq "Ubicloud - InvalidRequest"
    expect(page).to have_content "expected string but received {}"
  ensure
    ENV.delete("SHOW_WEB_ERROR_PAGE")
  end

  it "handles expected errors" do
    expect(Clog).to receive(:emit).with("route exception", instance_of(Hash)).and_call_original

    visit "/webhook/test-error"

    expect(page.title).to eq("Ubicloud - UnexceptedError")
  end

  it "raises unexpected errors in test environment" do
    expect(Clog).not_to receive(:emit)

    expect { visit "/webhook/test-error?message=treat+as+unexpected+error" }.to raise_error(RuntimeError, "treat as unexpected error")
  end

  it "does not have broken links" do
    create_account
    login

    visited = {"" => true}
    failures = []
    queue = Queue.new
    queue.push([nil, "/"])

    pop = lambda do
      queue.pop(true)
    rescue ThreadError
    end

    while (tuple = pop.call)
      from, path = tuple

      next if visited[path]

      visited[path] = true
      visit path

      if page.status_code == 404
        failures << [from, path]
      end

      if page.response_headers["content-type"].include?("text/html")
        links = page.all("a").map do |a|
          a["href"].sub(/#.*\z/, "")
        end

        links.reject! do |path|
          path.empty? || path.start_with?(%r{https://|mailto:})
        end

        links.each do |path|
          queue.push [page.current_path, path]
        end
      end
    end

    expect(failures).to be_empty
  end
end
