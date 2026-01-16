# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "PaymentMethod" do
  include AdminModelSpecHelper

  before do
    @instance = create_payment_method
    admin_account_setup_and_login
  end

  it "displays the PaymentMethod instance page correctly" do
    click_link "PaymentMethod"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - PaymentMethod - Browse"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - PaymentMethod #{@instance.ubid}"
  end
end
