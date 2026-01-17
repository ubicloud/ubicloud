# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "Strand" do
  include AdminModelSpecHelper

  before do
    @instance = create_strand
    admin_account_setup_and_login
  end

  it "displays the Strand instance page correctly" do
    click_link "Strand"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - Strand - Browse"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - Strand #{@instance.ubid}"
  end
end
