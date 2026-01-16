# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "Semaphore" do
  include AdminModelSpecHelper

  before do
    @instance = create_semaphore
    admin_account_setup_and_login
  end

  it "displays the Semaphore instance page correctly" do
    click_link "Semaphore"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - Semaphore"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - Semaphore #{@instance.ubid}"
  end
end
