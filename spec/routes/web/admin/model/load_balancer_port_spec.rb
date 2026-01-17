# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "LoadBalancerPort" do
  include AdminModelSpecHelper

  before do
    @instance = create_load_balancer_port
    admin_account_setup_and_login
  end

  it "displays the LoadBalancerPort instance page correctly" do
    click_link "LoadBalancerPort"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - LoadBalancerPort"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - LoadBalancerPort #{@instance.ubid}"
  end
end
