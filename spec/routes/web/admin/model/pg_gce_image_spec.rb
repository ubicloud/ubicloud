# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "PgGceImage" do
  include AdminModelSpecHelper

  before do
    @instance = create_pg_gce_image
    admin_account_setup_and_login
  end

  it "displays the PgGceImage instance page correctly" do
    click_link "PgGceImage"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - PgGceImage"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - PgGceImage #{@instance.ubid}"
  end
end
