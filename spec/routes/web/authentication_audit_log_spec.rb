# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "authentication audit log" do
  let(:user) { create_account }
  let(:project) { user.create_project_with_default_policy("project-1") }

  def insert_account_audit_log(account_id:, message: "login", metadata: {"ip" => "127.0.0.1"}, at: Sequel::CURRENT_TIMESTAMP)
    DB[:account_authentication_audit_log].returning(:id).insert(
      account_id:,
      message:,
      metadata: Sequel.pg_jsonb(metadata),
      at:,
    ).first[:id]
  end

  def audit_log_content
    page.all("#authentication-audit-log-table td:not(:first-child):not(:only-child)").map(&:text)
  end

  describe "account authentication audit log" do
    describe "unauthenticated" do
      it "redirects to login" do
        visit "/account/authentication-audit-log"

        expect(page.title).to eq("Ubicloud - Login")
      end
    end

    describe "authenticated" do
      before do
        login(user.email)
        DB[:account_authentication_audit_log].delete
      end

      it "can view own authentication audit log entries" do
        insert_account_audit_log(account_id: user.id, message: "login", metadata: {"ip" => "1.2.3.4", "via" => "password"})

        visit "/account/authentication-audit-log"

        expect(page.title).to eq("Ubicloud - Authentication Audit Log")
        expect(audit_log_content).to eq(["login", "ip: 1.2.3.4, via: password"])
      end

      it "does not show entries from other accounts" do
        other = create_account("other@example.com", with_project: false)
        insert_account_audit_log(account_id: other.id, message: "login_from_other")

        visit "/account/authentication-audit-log"
        expect(audit_log_content).to eq([])
      end

      it "can filter by action" do
        insert_account_audit_log(account_id: user.id, message: "login")
        insert_account_audit_log(account_id: user.id, message: "login_failure")

        visit "/account/authentication-audit-log"
        expect(audit_log_content).to eq(["login", "ip: 127.0.0.1", "login_failure", "ip: 127.0.0.1"])

        click_link "login_failure"
        expect(audit_log_content).to eq(["login_failure", "ip: 127.0.0.1"])

        fill_in "Action", with: "login"
        click_button "Search"
        expect(audit_log_content).to eq(["login", "ip: 127.0.0.1"])
      end

      it "can filter by metadata" do
        insert_account_audit_log(account_id: user.id, message: "login", metadata: {"ip" => "1.2.3.4"})
        insert_account_audit_log(account_id: user.id, message: "login_failure", metadata: {"ip" => "9.9.9.9"})

        visit "/account/authentication-audit-log"
        expect(audit_log_content).to eq(["login", "ip: 1.2.3.4", "login_failure", "ip: 9.9.9.9"])

        click_link "ip: 1.2.3.4"
        expect(audit_log_content).to eq(["login", "ip: 1.2.3.4"])

        fill_in "Metadata", with: "ip=9.9.9.9"
        click_button "Search"
        expect(audit_log_content).to eq(["login_failure", "ip: 9.9.9.9"])
      end

      it "shows no data rows for invalid metadata JSON" do
        insert_account_audit_log(account_id: user.id, message: "login")

        visit "/account/authentication-audit-log?metadata=not-json"
        expect(audit_log_content).to eq([])
      end
    end
  end

  describe "project authentication audit log" do
    describe "unauthenticated" do
      it "redirects to login" do
        visit "#{project.path}/audit-log/authentication"

        expect(page.title).to eq("Ubicloud - Login")
      end
    end

    describe "authenticated" do
      before do
        login(user.email)
        project.set_ff_authentication_audit_log(true)
        DB[:account_authentication_audit_log].delete
      end

      it "cannot view project authentication audit log entries without authentication_audit_log feature flag" do
        project.set_ff_authentication_audit_log(false)

        visit project.path
        expect(page).to have_no_content "View Authentication Audit Logs"

        visit "#{project.path}/audit-log/authentication"
        expect(page.title).to eq("Ubicloud - ResourceNotFound")
      end

      it "can view project authentication audit log entries" do
        insert_account_audit_log(account_id: user.id, message: "login", metadata: {"ip" => "1.2.3.4"})

        visit project.path
        click_link "View Authentication Audit Logs"

        expect(page.title).to eq("Ubicloud - project-1 - Authentication Audit Log")
        expect(audit_log_content).to eq(["login", user.ubid, "ip: 1.2.3.4"])
      end

      it "does not show entries from accounts not in project" do
        other = create_account("other@example.com", with_project: false)
        insert_account_audit_log(account_id: other.id, message: "login_from_other")

        visit "#{project.path}/audit-log/authentication"
        expect(audit_log_content).to eq([])
      end

      it "can filter by action" do
        insert_account_audit_log(account_id: user.id, message: "login")
        insert_account_audit_log(account_id: user.id, message: "login_failure")

        visit "#{project.path}/audit-log/authentication"
        expect(audit_log_content).to eq([
          "login", user.ubid, "ip: 127.0.0.1",
          "login_failure", user.ubid, "ip: 127.0.0.1",
        ])

        click_link "login_failure"
        expect(audit_log_content).to eq(["login_failure", user.ubid, "ip: 127.0.0.1"])

        fill_in "Action", with: "login"
        click_button "Search"
        expect(audit_log_content).to eq(["login", user.ubid, "ip: 127.0.0.1"])
      end

      it "can filter by metadata" do
        insert_account_audit_log(account_id: user.id, message: "login", metadata: {"ip" => "1.2.3.4"})
        insert_account_audit_log(account_id: user.id, message: "login_failure", metadata: {"ip" => "9.9.9.9"})

        visit "#{project.path}/audit-log/authentication"
        expect(audit_log_content).to eq([
          "login", user.ubid, "ip: 1.2.3.4",
          "login_failure", user.ubid, "ip: 9.9.9.9",
        ])

        click_link "ip: 1.2.3.4"
        expect(audit_log_content).to eq(["login", user.ubid, "ip: 1.2.3.4"])

        fill_in "Metadata", with: "ip=9.9.9.9"
        click_button "Search"
        expect(audit_log_content).to eq(["login_failure", user.ubid, "ip: 9.9.9.9"])
      end

      it "can filter by account name, email, and ubid" do
        user.update(name: "Test-Name")
        other = create_account("other@example.com", with_project: false)
        other.update(name: "Other-Name")
        project.add_account(other)
        insert_account_audit_log(account_id: user.id, message: "login")
        insert_account_audit_log(account_id: other.id, message: "login_failure")

        visit "#{project.path}/audit-log/authentication"
        expect(audit_log_content).to eq([
          "login", "Test-Name", "ip: 127.0.0.1",
          "login_failure", "Other-Name", "ip: 127.0.0.1",
        ])

        click_link "Test-Name"
        expect(audit_log_content).to eq(["login", "Test-Name", "ip: 127.0.0.1"])

        fill_in "Account", with: "Other-Name"
        click_button "Search"
        expect(audit_log_content).to eq(["login_failure", "Other-Name", "ip: 127.0.0.1"])

        fill_in "Account", with: user.email
        click_button "Search"
        expect(audit_log_content).to eq(["login", "Test-Name", "ip: 127.0.0.1"])

        fill_in "Account", with: other.ubid
        click_button "Search"
        expect(audit_log_content).to eq(["login_failure", "Other-Name", "ip: 127.0.0.1"])

        fill_in "Account", with: "not-a-ubid-or-name"
        click_button "Search"
        expect(audit_log_content).to eq([])
      end

      it "returns 403 when user lacks Project:auditlog permission" do
        project_wo_permissions = user.create_project_with_default_policy("project-2", default_policy: nil)

        visit "#{project_wo_permissions.path}/audit-log/authentication"

        expect(page.title).to eq("Ubicloud - Forbidden")
      end
    end
  end
end
