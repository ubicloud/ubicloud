# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "/prefix1" do
  it "has a page title" do
    visit "/prefix1"
    expect(page.title).to eq("UbiCloud/Login")
    # ...
  end
end
