# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "RemoteStorageServer" do
  include AdminModelSpecHelper

  before do
    @instance = create_remote_storage_server
    admin_account_setup_and_login
  end

  it "displays the RemoteStorageServer instance page correctly" do
    click_link "RemoteStorageServer"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - RemoteStorageServer"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - RemoteStorageServer #{@instance.ubid}"
  end
end
