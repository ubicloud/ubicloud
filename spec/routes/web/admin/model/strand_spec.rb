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

  it "links raw uuids in the stack as ubids" do
    vm = create_vm
    @instance.update(stack: [{"remaining" => [vm.id], "current" => "00000000-0000-0000-0000-000000000000"}])

    visit "/model/Strand/#{@instance.ubid}"
    expect(page).to have_link(vm.ubid, href: "/model/Vm/#{vm.ubid}")
    expect(page.find("pre").text).to include "#{vm.id} [#{vm.ubid}]"
    expect(page).to have_content "00000000-0000-0000-0000-000000000000"
    expect(page).to have_no_link "00000000-0000-0000-0000-000000000000"
  end
end
