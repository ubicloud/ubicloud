require_relative 'spec_helper'

describe '/prefix1' do
  it "should " do
    visit '/prefix1'
    page.title.must_equal 'App'
    # ...
  end
end
