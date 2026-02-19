# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "PostgresResource" do
  include AdminModelSpecHelper

  before do
    @instance = create_postgres_resource
    admin_account_setup_and_login
  end

  it "displays the PostgresResource instance page correctly" do
    click_link "PostgresResource"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - PostgresResource - Browse"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - PostgresResource #{@instance.ubid}"
  end
end
