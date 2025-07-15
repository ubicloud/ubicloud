# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin do
  def object_data
    page.all(".object-table tbody tr").map { it.all("td").map(&:text) }.to_h.transform_keys(&:to_sym).except(:created_at)
  end

  it "allows searching by ubid and navigating to related objects" do
    account = create_account

    visit "/"
    expect(page.title).to eq "Ubicloud Admin"

    fill_in "UBID", with: account.ubid
    click_button "Show Object"
    expect(page.title).to eq "Ubicloud Admin - Account #{account.ubid}"
    expect(object_data).to eq(email: "user@example.com", name: "", status_id: "2", suspended_at: "")

    project = account.projects.first
    click_link project.ubid
    expect(page.title).to eq "Ubicloud Admin - Project #{project.ubid}"
    expect(object_data).to eq(billable: "true", billing_info_id: "", credit: "0.0", discount: "0", feature_flags: "{}", name: "Default", reputation: "new", visible: "true")

    subject_tag = project.subject_tags.first
    click_link subject_tag.ubid
    expect(page.title).to eq "Ubicloud Admin - SubjectTag #{subject_tag.ubid}"
    expect(object_data).to eq(name: "Admin", project_id: project.ubid)

    # Column Link
    click_link project.ubid
    expect(page.title).to eq "Ubicloud Admin - Project #{project.ubid}"
  end

  it "handles request for invalid ubid" do
    visit "/"
    fill_in "UBID", with: "foo"
    click_button "Show Object"
    expect(page.title).to eq "Ubicloud Admin"
    expect(page).to have_flash_error("Invalid ubid provided")

    fill_in "UBID", with: "ts1cyaqvp5ha6j5jt8ypbyagw9"
    click_button "Show Object"
    expect(page.title).to eq "Ubicloud Admin - File Not Found"
  end

  it "handles request for invalid model or missing object" do
    visit "/model/Foo/ts1cyaqvp5ha6j5jt8ypbyagw9"
    expect(page.title).to eq "Ubicloud Admin - File Not Found"

    visit "/model/ArchivedRecord/ts1cyaqvp5ha6j5jt8ypbyagw9"
    expect(page.title).to eq "Ubicloud Admin - File Not Found"

    visit "/model/SubjectTag/ts1cyaqvp5ha6j5jt8ypbyagw9"
    expect(page.title).to eq "Ubicloud Admin - File Not Found"
  end

  it "handles 404 page" do
    visit "/invalid-page"
    expect(page.title).to eq "Ubicloud Admin - File Not Found"
  end
end
