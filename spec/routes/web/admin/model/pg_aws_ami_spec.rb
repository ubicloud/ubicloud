# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "PgAwsAmi" do
  include AdminModelSpecHelper

  before do
    @instance = create_pg_aws_ami
    admin_account_setup_and_login
  end

  it "displays the PgAwsAmi instance page correctly" do
    click_link "PgAwsAmi"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - PgAwsAmi"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - PgAwsAmi #{@instance.ubid}"
  end
end
