# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "KubernetesNodepool" do
  include AdminModelSpecHelper

  before do
    @instance = create_kubernetes_nodepool
    admin_account_setup_and_login
  end

  it "displays the KubernetesNodepool instance page correctly" do
    click_link "KubernetesNodepool"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - KubernetesNodepool"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - KubernetesNodepool #{@instance.ubid}"
  end
end
