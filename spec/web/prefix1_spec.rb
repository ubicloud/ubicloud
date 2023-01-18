require_relative "spec_helper"

RSpec.describe "/prefix1" do
  it "should " do
    visit "/prefix1"
    page.title.must_equal "Clover"
    # ...
  end
end
