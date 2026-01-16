# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "MinioServer" do
  include AdminModelSpecHelper

  before do
    @instance = create_minio_server
    admin_account_setup_and_login
  end

  it "displays the MinioServer instance page correctly" do
    click_link "MinioServer"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - MinioServer"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - MinioServer #{@instance.ubid}"
  end
end
