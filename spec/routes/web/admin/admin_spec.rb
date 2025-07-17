# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin do
  def object_data
    page.all(".object-table tbody tr").map { it.all("td").map(&:text) }.to_h.transform_keys(&:to_sym).except(:created_at)
  end

  before do
    admin_account_setup_and_login
  end

  let(:vm_pool) do
    vp = VmPool.create(
      size: 3,
      vm_size: "standard-2",
      boot_image: "img",
      location_id: Location::HETZNER_FSN1_ID,
      storage_size_gib: 86
    )
    Strand.create(prog: "Vm::VmPool", label: "create_new_vm") { it.id = vp.id }
    vp
  end

  it "allows searching by ubid and navigating to related objects" do
    expect(page.title).to eq "Ubicloud Admin"

    account = create_account
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

  it "shows semaphores set on the object, if any" do
    fill_in "UBID", with: vm_pool.ubid
    click_button "Show Object"
    expect(page.title).to eq "Ubicloud Admin - VmPool #{vm_pool.ubid}"
    expect(page).to have_no_content "Semaphores Set:"

    vm_pool.incr_destroy
    page.refresh
    expect(page).to have_content "Semaphores Set: destroy"
  end

  it "shows object's strand, if any" do
    fill_in "UBID", with: vm_pool.ubid
    click_button "Show Object"
    path = page.current_path
    expect(page.title).to eq "Ubicloud Admin - VmPool #{vm_pool.ubid}"
    expect(page).to have_content "Strand: Vm::VmPool#create_new_vm | schedule: 2"
    expect(page).to have_no_content "| try"

    vm_pool.strand.update(try: 3)
    visit path
    expect(page).to have_content "| try: 3"

    click_link "Strand"
    expect(page.title).to eq "Ubicloud Admin - Strand #{vm_pool.ubid}"

    vm_pool.strand.destroy
    visit path
    expect(page).to have_no_content "Strand"
  end

  it "handles request for invalid ubid" do
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
