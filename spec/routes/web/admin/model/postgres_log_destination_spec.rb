# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "PostgresLogDestination" do
  include AdminModelSpecHelper

  before do
    @instance = create_postgres_log_destination
    admin_account_setup_and_login
  end

  it "displays the PostgresLogDestination instance page correctly" do
    click_link "PostgresLogDestination"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - PostgresLogDestination"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - PostgresLogDestination #{@instance.ubid}"
  end
end
