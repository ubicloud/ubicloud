# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "SshPublicKey" do
  include AdminModelSpecHelper

  before do
    @instance = create_ssh_public_key
    admin_account_setup_and_login
  end

  it "displays the SshPublicKey instance page correctly" do
    click_link "SshPublicKey"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - SshPublicKey"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - SshPublicKey #{@instance.ubid}"
  end
end
