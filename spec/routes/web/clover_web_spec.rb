# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover do
  it "handles CSRF token errors" do
    visit "/login"
    find(".rodauth input[name=_csrf]", visible: false).set("")
    click_button "Sign in"

    expect(page.status_code).to eq(400)
    expect(page).to have_flash_error("An invalid security token submitted with this request, please try again")
  end

  it "does not redirect to requested path if path is too long" do
    create_account
    visit("/a" * 2048)
    expect(page.status_code).to eq(200)
    expect(page).to have_current_path("/login", ignore_query: true)
    fill_in "Email Address", with: TEST_USER_EMAIL
    fill_in "Password", with: TEST_USER_PASSWORD
    click_button "Sign in"
    expect(page.title).to end_with("Dashboard")
  end

  if ENV["CLOVER_FREEZE"] != "1"
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
    expect { post "/webhook/test-no-audit-logging/bad" }.to raise_error(RuntimeError, "unsupported audit_log action: bad_action")
  end

  it "handles expected errors" do
    expect(Clog).to receive(:emit).with("route exception").and_call_original

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

  it "returns ipv4 list from cached file" do
    vmh1, vmh2 = Array.new(2) { create_vm_host }
    Address.create(cidr: "1.1.1.1/32", routed_to_host_id: vmh1.id) { it.id = vmh1.id }
    Address.create(cidr: "3.3.3.3/27", routed_to_host_id: vmh2.id)
    Address.create(cidr: "2.2.2.2/27", routed_to_host_id: vmh1.id)
    Address.create(cidr: "3.3.3.3/28", routed_to_host_id: vmh2.id)
    Util.populate_ipv4_txt

    visit "/ips-v4"

    expect(page.status_code).to eq(200)
    expect(page.body).to eq("2.2.0.0/16\n3.3.0.0/16")
  end
end
