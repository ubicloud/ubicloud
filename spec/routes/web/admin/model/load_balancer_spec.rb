# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "LoadBalancer" do
  include AdminModelSpecHelper

  before do
    @instance = create_load_balancer
    admin_account_setup_and_login
  end

  it "displays the LoadBalancer instance page correctly" do
    click_link "LoadBalancer"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - LoadBalancer"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - LoadBalancer #{@instance.ubid}"
  end
end
