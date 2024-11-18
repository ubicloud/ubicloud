# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover do
  it "handles CSRF token errors" do
    visit "/login"
    find("input[name=_csrf]", visible: false).set("")
    click_button "Sign in"

    expect(page.status_code).to eq(200)
    expect(page).to have_content("An invalid security token submitted with this request")
  end

  it "handles expected errors" do
    expect(Clog).to receive(:emit).with("route exception").and_call_original

    visit "/webhook/test-error"

    expect(page.title).to eq("Ubicloud - UnexceptedError")
  end

  it "raises unexpected errors in test environment" do
    expect(Clog).not_to receive(:emit)

    expect { visit "/webhook/test-error?message=treat+as+unexpected+error" }.to raise_error(RuntimeError)
  end
end
