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
      at:
    ).first[:id]
  end

  # Returns rows that correspond to audit log entries (rows with non-empty id attribute)
  def data_rows(table_id = "authentication-audit-log-table")
    page.all("##{table_id} tbody tr[id!='']")
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
        expect(data_rows.length).to eq(1)
        expect(data_rows.first).to have_content("login")
        expect(data_rows.first).to have_content("ip: 1.2.3.4")
      end

      it "does not show entries from other accounts" do
        other = create_account("other@example.com", with_project: false)
        insert_account_audit_log(account_id: other.id, message: "login_from_other")

        visit "/account/authentication-audit-log"

        expect(data_rows).to be_empty
      end

      it "can filter by message" do
        insert_account_audit_log(account_id: user.id, message: "login")
        insert_account_audit_log(account_id: user.id, message: "login_failure")

        visit "/account/authentication-audit-log?action=login_failure"

        expect(data_rows.length).to eq(1)
        expect(data_rows.first).to have_content("login_failure")
      end

      it "can filter by metadata" do
        insert_account_audit_log(account_id: user.id, message: "login", metadata: {"ip" => "1.2.3.4"})
        insert_account_audit_log(account_id: user.id, message: "login_failure", metadata: {"ip" => "9.9.9.9"})

        visit "/account/authentication-audit-log?metadata=%7B%22ip%22%3A%221.2.3.4%22%7D"

        expect(data_rows.length).to eq(1)
        expect(data_rows.first).to have_content("login")
        expect(data_rows.first).to have_content("ip: 1.2.3.4")
      end

      it "shows no data rows for invalid metadata JSON" do
        insert_account_audit_log(account_id: user.id, message: "login")

        visit "/account/authentication-audit-log?metadata=not-json"

        expect(data_rows).to be_empty
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
        expect(data_rows.length).to eq(1)
        expect(data_rows.first).to have_content("login")
        expect(data_rows.first).to have_content("ip: 1.2.3.4")
      end

      it "does not show entries from accounts not in project" do
        other = create_account("other@example.com", with_project: false)
        insert_account_audit_log(account_id: other.id, message: "login_from_other")

        visit "#{project.path}/audit-log/authentication"

        expect(data_rows).to be_empty
      end

      it "can filter by message" do
        insert_account_audit_log(account_id: user.id, message: "login")
        insert_account_audit_log(account_id: user.id, message: "login_failure")

        visit "#{project.path}/audit-log/authentication?action=login_failure"

        expect(data_rows.length).to eq(1)
        expect(data_rows.first).to have_content("login_failure")
      end

      it "can filter by metadata" do
        insert_account_audit_log(account_id: user.id, message: "login", metadata: {"ip" => "1.2.3.4"})
        insert_account_audit_log(account_id: user.id, message: "login_failure", metadata: {"ip" => "9.9.9.9"})

        visit "#{project.path}/audit-log/authentication?metadata=%7B%22ip%22%3A%221.2.3.4%22%7D"

        expect(data_rows.length).to eq(1)
        expect(data_rows.first).to have_content("login")
      end

      it "can filter by account name" do
        user.update(name: "Test-Name")
        other = create_account("other@example.com", with_project: false)
        project.add_account(other)
        insert_account_audit_log(account_id: user.id, message: "login")
        insert_account_audit_log(account_id: other.id, message: "login_failure")

        visit "#{project.path}/audit-log/authentication?account=Test-Name"

        expect(data_rows.length).to eq(1)
        expect(data_rows.first).to have_content("login")
        expect(data_rows.first).to have_no_content("login_failure")
      end

      it "can filter by account email" do
        other = create_account("other@example.com", with_project: false)
        project.add_account(other)
        insert_account_audit_log(account_id: user.id, message: "login")
        insert_account_audit_log(account_id: other.id, message: "login_failure")

        visit "#{project.path}/audit-log/authentication?account=#{user.email}"

        expect(data_rows.length).to eq(1)
        expect(data_rows.first).to have_content("login")
        expect(data_rows.first).to have_no_content("login_failure")
      end

      it "can filter by account UBID" do
        other = create_account("other@example.com", with_project: false)
        project.add_account(other)
        insert_account_audit_log(account_id: user.id, message: "login")
        insert_account_audit_log(account_id: other.id, message: "login_failure")

        visit "#{project.path}/audit-log/authentication?account=#{user.ubid}"

        expect(data_rows.length).to eq(1)
        expect(data_rows.first).to have_content("login")
        expect(data_rows.first).to have_no_content("login_failure")
      end

      it "shows no data rows for unknown account filter" do
        insert_account_audit_log(account_id: user.id, message: "login")

        visit "#{project.path}/audit-log/authentication?account=not-a-ubid-or-name"

        expect(data_rows).to be_empty
      end

      it "resolves account name in results" do
        user.update(name: "Shown-Name")
        insert_account_audit_log(account_id: user.id, message: "login")

        visit "#{project.path}/audit-log/authentication"

        expect(page).to have_content("Shown-Name")
      end

      it "returns 403 when user lacks Project:auditlog permission" do
        project_wo_permissions = user.create_project_with_default_policy("project-2", default_policy: nil)

        visit "#{project_wo_permissions.path}/audit-log/authentication"

        expect(page.title).to eq("Ubicloud - Forbidden")
      end
    end
  end
end
