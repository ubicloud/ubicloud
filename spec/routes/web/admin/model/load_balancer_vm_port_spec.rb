# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "LoadBalancerVmPort" do
  include AdminModelSpecHelper

  before do
    @instance = create_load_balancer_vm_port
    admin_account_setup_and_login
  end

  it "displays the LoadBalancerVmPort instance page correctly" do
    click_link "LoadBalancerVmPort"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - LoadBalancerVmPort"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - LoadBalancerVmPort #{@instance.ubid}"
  end
end
