# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "KubernetesCluster" do
  include AdminModelSpecHelper

  before do
    @instance = create_kubernetes_cluster
    admin_account_setup_and_login
  end

  it "displays the KubernetesCluster instance page correctly" do
    click_link "KubernetesCluster"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - KubernetesCluster"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - KubernetesCluster #{@instance.ubid}"
  end
end
