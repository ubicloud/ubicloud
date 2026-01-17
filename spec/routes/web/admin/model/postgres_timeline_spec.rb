# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "PostgresTimeline" do
  include AdminModelSpecHelper

  before do
    @instance = create_postgres_timeline
    admin_account_setup_and_login
  end

  it "displays the PostgresTimeline instance page correctly" do
    click_link "PostgresTimeline"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - PostgresTimeline"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - PostgresTimeline #{@instance.ubid}"
  end
end
