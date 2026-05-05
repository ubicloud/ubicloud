# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "ParseableServer" do
  include AdminModelSpecHelper

  before do
    @instance = create_parseable_server
    admin_account_setup_and_login
  end

  it "displays the ParseableServer instance page correctly" do
    click_link "ParseableServer"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - ParseableServer"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - ParseableServer #{@instance.ubid}"
  end
end
