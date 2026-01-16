# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "Sshable" do
  include AdminModelSpecHelper

  before do
    @instance = create_sshable
    admin_account_setup_and_login
  end

  it "displays the Sshable instance page correctly" do
    click_link "Sshable"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - Sshable"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - Sshable #{@instance.ubid}"
  end
end
