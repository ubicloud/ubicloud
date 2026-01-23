# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "KubernetesEtcdBackup" do
  include AdminModelSpecHelper

  before do
    @instance = create_kubernetes_etcd_backup
    admin_account_setup_and_login
  end

  it "displays the KubernetesEtcBackup instance page correctly" do
    click_link "KubernetesEtcdBackup"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - KubernetesEtcdBackup"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - KubernetesEtcdBackup #{@instance.ubid}"
  end
end
