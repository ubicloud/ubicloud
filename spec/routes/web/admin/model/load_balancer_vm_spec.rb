# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "LoadBalancerVm" do
  include AdminModelSpecHelper

  before do
    @instance = create_load_balancer_vm
    admin_account_setup_and_login
  end

  it "displays the LoadBalancerVm instance page correctly" do
    click_link "LoadBalancerVm"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - LoadBalancerVm"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - LoadBalancerVm #{@instance.ubid}"
  end
end
