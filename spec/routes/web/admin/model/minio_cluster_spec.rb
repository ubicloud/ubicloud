# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "MinioCluster" do
  include AdminModelSpecHelper

  before do
    @instance = create_minio_cluster
    admin_account_setup_and_login
  end

  it "displays the MinioCluster instance page correctly" do
    click_link "MinioCluster"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - MinioCluster"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - MinioCluster #{@instance.ubid}"
  end
end
