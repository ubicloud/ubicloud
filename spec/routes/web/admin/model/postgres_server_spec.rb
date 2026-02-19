# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "PostgresServer" do
  include AdminModelSpecHelper

  before do
    @instance = create_postgres_server
    admin_account_setup_and_login
  end

  it "displays the PostgresServer instance page correctly" do
    click_link "PostgresServer"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - PostgresServer - Browse"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - PostgresServer #{@instance.ubid}"
  end
end
