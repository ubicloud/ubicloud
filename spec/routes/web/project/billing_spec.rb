# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "billing" do
  let(:user) { create_account }
  let(:project) { user.create_project_with_default_policy("project-1") }
  let(:project_wo_permissions) { user.create_project_with_default_policy("project-2", policy_body: []) }
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
    within find_by_id("desktop-menu") do
      expect { click_link "Billing" }.to raise_error Capybara::ElementNotFound
    end
    expect(page.title).to eq("Ubicloud - #{project.name}")

    visit "#{project.path}/billing"
    expect(page.status_code).to eq(501)
    expect(page).to have_content "Billing is not enabled. Set STRIPE_SECRET_KEY to enable billing."
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
      expect(Stripe::Checkout::Session).to receive(:create).and_return(OpenStruct.new({url: "#{project.path}/billing/success?session_id=session_123"}))
      expect(Stripe::Checkout::Session).to receive(:retrieve).with("session_123").and_return({"setup_intent" => "st_123456790"})
      expect(Stripe::SetupIntent).to receive(:retrieve).with("st_123456790").and_return({"customer" => "cs_1234567890", "payment_method" => "pm_1234567890"})
      expect(Stripe::Customer).to receive(:retrieve).with("cs_1234567890").and_return({"name" => "ACME Inc.", "address" => {"country" => "NL"}})
      expect(Stripe::PaymentMethod).to receive(:retrieve).with("pm_1234567890").and_return({"card" => {"brand" => "visa"}})

      visit project.path

      within find_by_id("desktop-menu") do
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
    end

    it "can update billing info" do
      expect(Stripe::Customer).to receive(:retrieve).with(billing_info.stripe_id).and_return(
        {"name" => "Old Inc.", "address" => {"country" => "NL"}},
        {"name" => "New Inc.", "address" => {"country" => "US"}}
      ).twice
      expect(Stripe::Customer).to receive(:update).with(billing_info.stripe_id, anything)

      visit "#{project.path}/billing"

      expect(page.title).to eq("Ubicloud - Project Billing")
      fill_in "Billing Name", with: "New Inc."
      select "United States", from: "Country"

      click_button "Update"

      expect(page.status_code).to eq(200)
      expect(page).to have_field("Billing Name", with: "New Inc.")
      expect(page).to have_field("Country", with: "US")
    end

    it "can add new payment method" do
      expect(Stripe::Customer).to receive(:retrieve).with(billing_info.stripe_id).and_return({"name" => "ACME Inc.", "address" => {"country" => "NL"}}).twice
      expect(Stripe::PaymentMethod).to receive(:retrieve).with(payment_method.stripe_id).and_return({"card" => {"brand" => "visa"}}).twice
      expect(Stripe::PaymentMethod).to receive(:retrieve).with("pm_222222222").and_return({"card" => {"brand" => "mastercard"}})
      expect(Stripe::Checkout::Session).to receive(:create).and_return(OpenStruct.new({url: "#{project.path}/billing/success?session_id=session_123"}))
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

    it "raises not found when payment method not exists" do
      visit "#{project.path}/billing/payment-method/08s56d4kaj94xsmrnf5v5m3mav"

      expect(page.title).to eq("Ubicloud - Resource not found")
      expect(page.status_code).to eq(404)
      expect(page).to have_content "Resource not found"
    end

    it "raises not found when add payment method if project not exists" do
      visit "#{project.path}/billing/payment-method/create"

      expect(page.title).to eq("Ubicloud - Resource not found")
      expect(page.status_code).to eq(404)
      expect(page).to have_content "Resource not found"
    end

    it "can't delete last payment method" do
      expect(Stripe::Customer).to receive(:retrieve).with(billing_info.stripe_id).and_return({"name" => "ACME Inc.", "address" => {"country" => "NL"}})
      expect(Stripe::PaymentMethod).to receive(:retrieve).with(payment_method.stripe_id).and_return({"card" => {"brand" => "visa"}})

      visit "#{project.path}/billing"

      # We send delete request manually instead of just clicking to button because delete action triggered by JavaScript.
      # UI tests run without a JavaScript enginer.
      btn = find "#payment-method-#{payment_method.ubid} .delete-btn"
      page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}

      expect(page.status_code).to eq(400)
      expect(page.body).to eq({message: "You can't delete the last payment method of a project."}.to_json)
      expect(billing_info.reload.payment_methods.count).to eq(1)
    end

    it "can delete payment method" do
      payment_method_2 = PaymentMethod.create_with_id(billing_info_id: billing_info.id, stripe_id: "pm_2222222222")
      expect(Stripe::Customer).to receive(:retrieve).with(billing_info.stripe_id).and_return({"name" => "ACME Inc.", "address" => {"country" => "NL"}})
      expect(Stripe::PaymentMethod).to receive(:retrieve).with(payment_method.stripe_id).and_return({"card" => {"brand" => "visa"}})
      expect(Stripe::PaymentMethod).to receive(:retrieve).with(payment_method_2.stripe_id).and_return({"card" => {"brand" => "mastercard"}})
      expect(Stripe::PaymentMethod).to receive(:detach).with(payment_method.stripe_id)

      visit "#{project.path}/billing"

      # We send delete request manually instead of just clicking to button because delete action triggered by JavaScript.
      # UI tests run without a JavaScript enginer.
      btn = find "#payment-method-#{payment_method.ubid} .delete-btn"
      page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}

      expect(page.status_code).to eq(200)
      expect(page.body).to eq({message: "Deleting #{payment_method.ubid}"}.to_json)
      expect(billing_info.reload.payment_methods.count).to eq(1)
    end
  end
end
