# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "ObjectTag" do
  include AdminModelSpecHelper

  before do
    @instance = create_object_tag
    admin_account_setup_and_login
  end

  it "displays the ObjectTag instance page correctly" do
    click_link "ObjectTag"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - ObjectTag"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - ObjectTag #{@instance.ubid}"
  end
end
