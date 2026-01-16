# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "Invoice" do
  include AdminModelSpecHelper

  before do
    @instance = create_invoice
    admin_account_setup_and_login
  end

  it "displays the Invoice instance page correctly" do
    click_link "Invoice"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - Invoice - Browse"

    expect(Aws::S3::Client).to receive(:new).and_return(Aws::S3::Client.new(stub_responses: true))
    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - Invoice #{@instance.ubid}"
  end
end
