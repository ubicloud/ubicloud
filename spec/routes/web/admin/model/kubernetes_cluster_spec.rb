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
    expect(page.title).to eq "Ubicloud Admin - KubernetesCluster - Browse"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - KubernetesCluster #{@instance.ubid}"
  end

  it "lists the cluster with its nodepools in the table" do
    KubernetesNodepool.create(name: "np-a", node_count: 2, kubernetes_cluster_id: @instance.id, target_node_size: "standard-4", version: "v1.36")
    KubernetesNodepool.create(name: "np-b", node_count: 1, kubernetes_cluster_id: @instance.id, target_node_size: "standard-2", target_node_storage_size_gib: 100, version: "v1.35")
    visit "/model/Project/#{@instance.project.ubid}"
    within(".association", text: "kubernetes_clusters") { click_link "(table)" }
    expect(page.title).to eq "Ubicloud Admin - KubernetesCluster - Search"
    cluster_row = [
      "test-cluster", "test-project", "hetzner-fsn1", @instance.version, "3", "standard-2", "40 (default)", @instance.created_at.to_s,
      "2 nodepoolsnp-a: 2 x standard-4, 80 (default) GiB, v1.36np-b: 1 x standard-2, 100 GiB, v1.35",
    ]
    expect(page.all("#autoforme_content td").map(&:text)).to eq cluster_row

    visit "/autoforme/KubernetesCluster/search"
    fill_in "Name", with: "test-cluster"
    select @instance.version, from: "Version"
    click_button "Search"
    expect(page.all("#autoforme_content td").map(&:text)).to eq cluster_row
  end
end
