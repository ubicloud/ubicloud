# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "MinioPool" do
  include AdminModelSpecHelper

  before do
    @instance = create_minio_pool
    admin_account_setup_and_login
  end

  it "displays the MinioPool instance page correctly" do
    click_link "MinioPool"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - MinioPool"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - MinioPool #{@instance.ubid}"
  end
end
