# frozen_string_literal: true

# Excon stubs are global and shadow the catch-all stub webmock uses to
# serve stub_request; spec_helper restores them after each example.
# Whichever twin runs second fails if the first one's stub leaked.
RSpec.describe Excon, "stub isolation" do
  2.times do |i|
    it "does not see Excon stubs from other examples (#{i + 1})" do
      stub_request(:get, "https://excon-leak.test/").to_return(status: 400)
      expect { described_class.new("https://excon-leak.test").get(expects: 200) }.to raise_error Excon::Error::BadRequest
      described_class.stub({host: "excon-leak.test"}, {status: 200, body: ""})
    end
  end
end
