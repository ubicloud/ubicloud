# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "Project" do
  include AdminModelSpecHelper

  before do
    @instance = create_project
    admin_account_setup_and_login
  end

  it "displays the Project instance page correctly" do
    click_link "Project"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - Project - Browse"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - Project #{@instance.ubid}"
  end
end
