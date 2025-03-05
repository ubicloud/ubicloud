# frozen_string_literal: true

require_relative "../spec_helper"
require "pdf-reader"
require "stripe"

RSpec.describe Clover, "billing" do
  let(:user) { create_account }
  let(:project) { user.create_project_with_default_policy("project-1") }
  let(:project_wo_permissions) { user.create_project_with_default_policy("project-2", default_policy: nil) }
  let(:billing_info) do
    bi = BillingInfo.create_with_id(stripe_id: "cs_1234567890")
    project.update(billing_info_id: bi.id)
    bi
  end

  let(:payment_method) { PaymentMethod.create_with_id(billing_info_id: billing_info.id, stripe_id: "pm_1234567890") }

  before do
    login(user.email)
  end

  it "disabled when Stripe secret key not provided" do
    allow(Config).to receive(:stripe_secret_key).and_return(nil)

    visit project.path
    within "#desktop-menu" do
      expect { click_link "Billing" }.to raise_error Capybara::ElementNotFound
    end
    expect(page.title).to eq("Ubicloud - #{project.name}")

    visit "#{project.path}/billing"
    expect(page.status_code).to eq(501)
    expect(page.body).to eq "Billing is not enabled. Set STRIPE_SECRET_KEY to enable billing."
  end

  it "tag payment method fraud after account suspension" do
    expect(payment_method.reload.fraud).to be(false)
    user.suspend
    expect(payment_method.reload.fraud).to be(true)
  end

  context "when Stripe enabled" do
    before do
      allow(Config).to receive(:stripe_secret_key).and_return("secret_key")
    end

    it "raises forbidden when does not have permissions" do
      project_wo_permissions
      visit "#{project_wo_permissions.path}/billing"

      expect(page.title).to eq("Ubicloud - Forbidden")
      expect(page.status_code).to eq(403)
      expect(page).to have_content "Forbidden"
    end

    it "can create billing info" do
      # rubocop:disable RSpec/VerifiedDoubles
      expect(Stripe::Checkout::Session).to receive(:create).and_return(double(Stripe::Checkout::Session, url: "#{project.path}/billing/success?session_id=session_123"))
      expect(Stripe::PaymentIntent).to receive(:create).and_return(double(Stripe::PaymentIntent, status: "requires_capture", id: "pi_1234567890"))
      # rubocop:enable RSpec/VerifiedDoubles
      expect(Stripe::Checkout::Session).to receive(:retrieve).with("session_123").and_return({"setup_intent" => "st_123456790"})
      expect(Stripe::SetupIntent).to receive(:retrieve).with("st_123456790").and_return({"customer" => "cs_1234567890", "payment_method" => "pm_1234567890"})
      expect(Stripe::Customer).to receive(:retrieve).with("cs_1234567890").and_return({"name" => "ACME Inc.", "address" => {"country" => "NL"}, "metadata" => {"company_name" => "Foo Companye Name"}}).twice
      expect(Stripe::PaymentMethod).to receive(:retrieve).with("pm_1234567890").and_return({"card" => {"brand" => "visa"}}).thrice

      visit project.path

      within "#desktop-menu" do
        click_link "Billing"
      end

      expect(page.title).to eq("Ubicloud - Project Billing")
      click_button "Add new billing information"

      billing_info = project.reload.billing_info
      expect(page.status_code).to eq(200)
      expect(billing_info.stripe_id).to eq("cs_1234567890")
      expect(page).to have_field("Billing Name", with: "ACME Inc.")
      expect(billing_info.payment_methods.first.stripe_id).to eq("pm_1234567890")
      expect(page).to have_content "Visa"
      expect(page).to have_no_content "Discount"
      expect(page).to have_no_content "100%"

      project.this.update(discount: 100)
      page.refresh
      expect(page).to have_content "Discount"
      expect(page).to have_content "100%"
    end

    it "can not create billing info with unauthorized payment" do
      # rubocop:disable RSpec/VerifiedDoubles
      expect(Stripe::Checkout::Session).to receive(:create).and_return(double(Stripe::Checkout::Session, url: "#{project.path}/billing/success?session_id=session_123"))
      expect(Stripe::PaymentIntent).to receive(:create).and_return(double(Stripe::PaymentIntent, status: "canceled", id: "pi_1234567890"))
      # rubocop:enable RSpec/VerifiedDoubles
      expect(Stripe::Checkout::Session).to receive(:retrieve).with("session_123").and_return({"setup_intent" => "st_123456790"})
      expect(Stripe::SetupIntent).to receive(:retrieve).with("st_123456790").and_return({"customer" => "cs_1234567890", "payment_method" => "pm_1234567890"})
      expect(Stripe::PaymentMethod).to receive(:retrieve).with("pm_1234567890").and_return({"card" => {"brand" => "visa"}}).once
      expect(Clog).to receive(:emit)

      visit project.path

      within "#desktop-menu" do
        click_link "Billing"
      end

      expect(page.title).to eq("Ubicloud - Project Billing")
      click_button "Add new billing information"

      expect(page.status_code).to eq(200)
      expect(page).to have_flash_error("We couldn't pre-authorize your card for verification. Please make sure it can be pre-authorized up to $5 or contact our support team at support@ubicloud.com.")
    end

    it "can update billing info" do
      expect(Stripe::Customer).to receive(:retrieve).with(billing_info.stripe_id).and_return(
        {"name" => "Old Inc.", "address" => {"country" => "NL"}, "metadata" => {"tax_id" => "123456"}},
        {"name" => "New Inc.", "address" => {"country" => "US"}, "metadata" => {"tax_id" => "456789"}}
      ).twice
      expect(Stripe::Customer).to receive(:update).with(billing_info.stripe_id, anything)

      visit "#{project.path}/billing"

      expect(page.title).to eq("Ubicloud - Project Billing")
      fill_in "Billing Name", with: "New Inc."
      select "United States", from: "Country"
      fill_in "Tax ID (Optional)", with: "456789"

      click_button "Update"

      expect(page.status_code).to eq(200)
      expect(page).to have_field("Billing Name", with: "New Inc.")
      expect(page).to have_field("Country", with: "US")
      expect(page).to have_field("Tax ID (Optional)", with: "456789")
    end

    it "shows error if billing info update failed" do
      expect(Stripe::Customer).to receive(:retrieve).with(billing_info.stripe_id).and_return(
        {"name" => "Old Inc.", "address" => {"country" => "NL"}, "metadata" => {"tax_id" => "123456"}},
        {"name" => "New Inc.", "address" => {"country" => "US"}, "metadata" => {"tax_id" => "456789"}}
      ).twice
      expect(Stripe::Customer).to receive(:update).and_raise(Stripe::InvalidRequestError.new("Invalid email address:    test@test.com", "email"))

      visit "#{project.path}/billing"

      expect(page.title).to eq("Ubicloud - Project Billing")
      fill_in "Billing Email", with: "  test@test.com"

      click_button "Update"

      expect(page.status_code).to eq(200)
      expect(page).to have_flash_error("Invalid email address: test@test.com")
    end

    it "can add new payment method" do
      expect(Stripe::Customer).to receive(:retrieve).with("cs_1234567890").and_return({"name" => "ACME Inc.", "address" => {"country" => "NL"}, "metadata" => {"company_name" => "Foo Companye Name"}}).twice
      expect(Stripe::PaymentMethod).to receive(:retrieve).with(payment_method.stripe_id).and_return({"card" => {"brand" => "visa"}}).twice
      expect(Stripe::PaymentMethod).to receive(:retrieve).with("pm_222222222").and_return({"card" => {"brand" => "mastercard"}}).twice
      # rubocop:disable RSpec/VerifiedDoubles
      expect(Stripe::Checkout::Session).to receive(:create).and_return(double(Stripe::Checkout::Session, url: "#{project.path}/billing/success?session_id=session_123"))
      expect(Stripe::PaymentIntent).to receive(:create).and_return(double(Stripe::PaymentIntent, status: "requires_capture", id: "pi_1234567890"))
      # rubocop:enable RSpec/VerifiedDoubles
      expect(Stripe::Checkout::Session).to receive(:retrieve).with("session_123").and_return({"setup_intent" => "st_123456790"})
      expect(Stripe::SetupIntent).to receive(:retrieve).with("st_123456790").and_return({"payment_method" => "pm_222222222"})

      visit "#{project.path}/billing"

      click_link "Add Payment Method"

      expect(page.status_code).to eq(200)
      expect(page.title).to eq("Ubicloud - Project Billing")
      expect(billing_info.payment_methods.count).to eq(2)
      expect(page).to have_content "Visa"
      expect(page).to have_content "Mastercard"
    end

    it "can't add fraud payment method" do
      fraud_payment_method = PaymentMethod.create_with_id(billing_info_id: billing_info.id, stripe_id: "pmi_1234567890", fraud: true, card_fingerprint: "cfg1234")
      expect(Stripe::Customer).to receive(:retrieve).with("cs_1234567890").and_return({"name" => "ACME Inc.", "address" => {"country" => "NL"}, "metadata" => {"company_name" => "Foo Companye Name"}}).twice
      expect(Stripe::PaymentMethod).to receive(:retrieve).with(fraud_payment_method.stripe_id).and_return({"card" => {"brand" => "visa"}}).twice
      expect(Stripe::PaymentMethod).to receive(:retrieve).with("pm_222222222").and_return({"card" => {"brand" => "mastercard", "fingerprint" => "cfg1234"}})
      # rubocop:disable RSpec/VerifiedDoubles
      expect(Stripe::Checkout::Session).to receive(:create).and_return(double(Stripe::Checkout::Session, url: "#{project.path}/billing/success?session_id=session_123"))
      # rubocop:enable RSpec/VerifiedDoubles
      expect(Stripe::Checkout::Session).to receive(:retrieve).with("session_123").and_return({"setup_intent" => "st_123456790"})
      expect(Stripe::SetupIntent).to receive(:retrieve).with("st_123456790").and_return({"payment_method" => "pm_222222222"})

      visit "#{project.path}/billing"

      click_link "Add Payment Method"

      expect(page.status_code).to eq(200)
      expect(page.title).to eq("Ubicloud - Project Billing")
      expect(billing_info.payment_methods.count).to eq(1)
      expect(page).to have_content "Visa"
      expect(page).to have_flash_error("Payment method you added is labeled as fraud. Please contact support.")
    end

    it "raises not found when payment method not exists" do
      visit "#{project.path}/billing/payment-method/08s56d4kaj94xsmrnf5v5m3mav"

      expect(page.title).to eq("Ubicloud - ResourceNotFound")
      expect(page.status_code).to eq(404)
      expect(page).to have_content "ResourceNotFound"
    end

    it "raises not found when add payment method if project not exists" do
      visit "#{project.path}/billing/payment-method/create"

      expect(page.title).to eq("Ubicloud - ResourceNotFound")
      expect(page.status_code).to eq(404)
      expect(page).to have_content "ResourceNotFound"
    end

    it "can't delete last payment method" do
      expect(Stripe::Customer).to receive(:retrieve).with("cs_1234567890").and_return({"name" => "ACME Inc.", "address" => {"country" => "NL"}, "metadata" => {"company_name" => "Foo Companye Name"}})
      expect(Stripe::PaymentMethod).to receive(:retrieve).with(payment_method.stripe_id).and_return({"card" => {"brand" => "visa"}})

      visit "#{project.path}/billing"

      # We send delete request manually instead of just clicking to button because delete action triggered by JavaScript.
      # UI tests run without a JavaScript engine.
      btn = find "#payment-method-#{payment_method.ubid} .delete-btn"
      page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}

      expect(page.status_code).to eq(400)
      expect(page.body).to eq({error: {message: "You can't delete the last payment method of a project."}}.to_json)
      expect(billing_info.reload.payment_methods.count).to eq(1)
    end

    it "can delete payment method" do
      payment_method_2 = PaymentMethod.create_with_id(billing_info_id: billing_info.id, stripe_id: "pm_2222222222")
      expect(Stripe::Customer).to receive(:retrieve).with("cs_1234567890").and_return({"name" => "ACME Inc.", "address" => {"country" => "NL"}, "metadata" => {"company_name" => "Foo Companye Name"}})
      expect(Stripe::PaymentMethod).to receive(:retrieve).with(payment_method.stripe_id).and_return({"card" => {"brand" => "visa"}})
      expect(Stripe::PaymentMethod).to receive(:retrieve).with(payment_method_2.stripe_id).and_return({"card" => {"brand" => "mastercard"}})
      expect(Stripe::PaymentMethod).to receive(:detach).with(payment_method.stripe_id)

      visit "#{project.path}/billing"

      # We send delete request manually instead of just clicking to button because delete action triggered by JavaScript.
      # UI tests run without a JavaScript enginer.
      btn = find "#payment-method-#{payment_method.ubid} .delete-btn"
      page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}

      expect(page.status_code).to eq(204)
      expect(page.body).to be_empty
      expect(billing_info.reload.payment_methods.count).to eq(1)
    end

    describe "invoices" do
      def billing_record(begin_time, end_time)
        vm = create_vm
        BillingRecord.create_with_id(
          project_id: billing_info.project.id,
          resource_id: vm.id,
          resource_name: vm.name,
          span: Sequel::Postgres::PGRange.new(begin_time, end_time),
          billing_rate_id: BillingRate.from_resource_properties("VmVCpu", vm.family, vm.location.name)["id"],
          amount: vm.vcpus
        )
      end

      it "list invoices of project" do
        expect(Stripe::Customer).to receive(:retrieve).with(billing_info.stripe_id).at_least(:once)
        bi = billing_record(Time.parse("2023-06-01"), Time.parse("2023-07-01"))
        InvoiceGenerator.new(bi.span.begin, bi.span.end, save_result: true).run
        invoice = Invoice.first

        visit "#{project.path}/billing"

        expect(page.status_code).to eq(200)
        expect(page.title).to eq("Ubicloud - Project Billing")
        expect(page).to have_content invoice.name

        invoice.content["cost"] = 123.45
        invoice.content["subtotal"] = 543.21
        invoice.this.update(content: invoice.content)
        page.refresh
        expect(page).to have_content("$123.45 ($543.21)")

        click_link invoice.name
      end

      it "show invoice details" do
        expect(Stripe::Customer).to receive(:retrieve).with("cs_1234567890").and_return({"name" => "ACME Inc.", "address" => {"country" => "NL"}, "metadata" => {"company_name" => "Foo Companye Name"}}).at_least(:once)
        bi = billing_record(Time.parse("2023-06-01"), Time.parse("2023-07-01"))
        100.times do
          billing_record(Time.parse("2023-06-01"), Time.parse("2023-06-01") + 10)
        end
        InvoiceGenerator.new(bi.span.begin, bi.span.end, save_result: true).run
        invoice = Invoice.first

        visit "#{project.path}/billing/invoice/#{invoice.ubid}"

        expect(page.status_code).to eq(200)
        expect(page.title).to eq("Ubicloud - #{invoice.name} Invoice")
        expect(page).to have_content invoice.name
        expect(page).to have_content "Aggregated"
        expect(page).to have_no_content "Tax ID:"
        expect(page.has_css?("#invoice-discount")).to be false
        expect(page.has_css?("#invoice-credit")).to be false

        content = invoice.content
        issuer_name = content["issuer_info"].delete("name")
        content["billing_info"]["tax_id"] = "123XYZ"
        content["discount"] = 1
        content["credit"] = 2
        content["free_inference_tokens_credit"] = 3
        expect(page).to have_content issuer_name
        invoice.this.update(content:)

        page.refresh
        expect(page).to have_content invoice.name
        expect(page).to have_content "Tax ID: 123XYZ"
        expect(page).to have_no_content issuer_name
        expect(find_by_id("invoice-discount").text).to eq "-$1.00"
        expect(find_by_id("invoice-credit").text).to eq "-$2.00"
        expect(find_by_id("invoice-free-inference-tokens").text).to eq "-$3.00"
      end

      it "show current invoice when no usage" do
        expect(Stripe::Customer).to receive(:retrieve).with(billing_info.stripe_id).at_least(:once)

        visit "#{project.path}/billing"

        expect(page.status_code).to eq(200)
        expect(page.title).to eq("Ubicloud - Project Billing")
        expect(page).to have_content "current"
        expect(page).to have_content "not finalized"

        click_link href: "#{project.path}/billing/invoice/current"
        expect(page).to have_content "Current Usage Summary"
        expect(page).to have_content "No resources"
      end

      it "list current invoice with last month usage" do
        expect(Stripe::Customer).to receive(:retrieve).with(billing_info.stripe_id).at_least(:once)
        br_previous = billing_record(Time.parse("2023-06-01"), Time.parse("2023-07-01"))
        br_current = billing_record(Time.parse("2023-07-01"), Time.parse("2023-07-15"))
        invoice_previous = InvoiceGenerator.new(br_previous.span.begin, br_previous.span.end, save_result: true).run.first
        invoice_current = InvoiceGenerator.new(br_current.span.begin, br_current.span.end, project_ids: [project.id]).run.first

        visit "#{project.path}/billing"

        expect(page.status_code).to eq(200)
        expect(page.title).to eq("Ubicloud - Project Billing")
        expect(page).to have_content "current"
        expect(page).to have_content "not finalized"
        expect(page).to have_content "$%0.02f" % invoice_current.content["cost"]
        expect(page).to have_content "$%0.02f" % invoice_previous.content["cost"]

        click_link href: "#{project.path}/billing/invoice/current"
        expect(page).to have_content "Current Usage Summary"
        expect(page).to have_content "$%0.02f" % invoice_current.content["cost"]
        expect(page).to have_content "less than $0.001"
      end

      it "show invoice full page for generating PDF" do
        expect(Stripe::Customer).to receive(:retrieve).with("cs_1234567890").and_return({"name" => "ACME Inc.", "address" => {"country" => "NL"}, "metadata" => {"company_name" => "Foo Companye Name"}}).at_least(:once)
        bi = billing_record(Time.parse("2023-06-01"), Time.parse("2023-07-01"))
        invoice = InvoiceGenerator.new(bi.span.begin, bi.span.end, save_result: true).run.first

        visit "#{project.path}/billing/invoice/#{invoice.ubid}?pdf=1"

        expect(page.status_code).to eq(200)
        text = PDF::Reader.new(StringIO.new(page.body)).pages.map(&:text).join(" ")
        expect(text).to include("ACME Inc. - Foo Companye Name")
        expect(text).to include("test-vm")
      end

      it "raises not found when invoice not exists" do
        visit "#{project.path}/billing/invoice/08s56d4kaj94xsmrnf5v5m3mav"

        expect(page.title).to eq("Ubicloud - ResourceNotFound")
        expect(page.status_code).to eq(404)
        expect(page).to have_content "ResourceNotFound"
      end
    end

    describe "usage alerts" do
      before do
        UsageAlert.create_with_id(project_id: project.id, user_id: user.id, name: "alert-1", limit: 101)
        UsageAlert.create_with_id(project_id: project_wo_permissions.id, user_id: user.id, name: "alert-2", limit: 100)
      end

      it "can list usage alerts" do
        visit "#{project.path}/billing"
        expect(page).to have_content "alert-1"
        expect(page).to have_no_content "alert-2"
      end

      it "can create usage alert" do
        visit "#{project.path}/billing"
        fill_in "alert_name", with: "alert-3"
        fill_in "limit", with: 200
        click_button "Add"

        expect(page).to have_content "alert-3"
      end

      it "can delete usage alert" do
        visit "#{project.path}/billing"
        expect(page).to have_content "alert-1"

        # We send delete request manually instead of just clicking to button because delete action triggered by JavaScript.
        # UI tests run without a JavaScript engine.
        btn = find "#alert-#{project.usage_alerts.first.ubid} .delete-btn"
        page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}

        visit "#{project.path}/billing"
        expect(page).to have_flash_notice "Usage alert alert-1 is deleted."

        visit "#{project.path}/billing"
        expect(page).to have_no_content "alert-1"
      end

      it "returns 404 if usage alert not found" do
        visit project.path + "/billing"
        expect(page).to have_content "alert-1"

        btn = find "#alert-#{project.usage_alerts.first.ubid} .delete-btn"

        project.usage_alerts.first.destroy
        page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}

        expect(page.status_code).to eq(404)
      end
    end
  end
end
