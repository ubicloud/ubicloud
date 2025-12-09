# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "PostgresInitScript" do
  include AdminModelSpecHelper

  before do
    @instance = create_postgres_init_script
    admin_account_setup_and_login
  end

  it "displays the PostgresInitScript instance page correctly" do
    click_link "PostgresInitScript"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - PostgresInitScript"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - PostgresInitScript #{@instance.ubid}"
  end
end
