# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "KubernetesNode" do
  include AdminModelSpecHelper

  before do
    @instance = create_kubernetes_node
    admin_account_setup_and_login
  end

  it "displays the KubernetesNode instance page correctly" do
    click_link "KubernetesNode"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - KubernetesNode"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - KubernetesNode #{@instance.ubid}"
  end
end
