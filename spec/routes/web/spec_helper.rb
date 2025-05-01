# frozen_string_literal: true

require_relative "../spec_helper"
Warning.ignore(:mismatched_indentations, File.expand_path("coverage/views")) if defined?(SimpleCov)

css_file = File.expand_path("../../../assets/css/app.css", __dir__)
File.write(css_file, "") unless File.file?(css_file)

require "capybara"
require "capybara/rspec"
require "capybara/validate_html5" if ENV["CLOVER_FREEZE"] == "1"

Gem.suffix_pattern

Capybara.app = Clover.app
Capybara.exact = true

module RackTestPlus
  include Rack::Test::Methods

  def app
    Capybara.app
  end
end

# Work around Middleware should not call #each error.
# Fix bugs with cookies, because the default behavior
# reuses the rack env of the last request, which is not valid.
class Capybara::RackTest::Browser
  remove_method :refresh
  def refresh
    visit last_request.fullpath
  end
end

RSpec.configure do |config|
  config.include RackTestPlus
  config.include Capybara::DSL
  config.after do
    Capybara.reset_sessions!
    Capybara.use_default_driver
  end

  class RSpec::Matchers::DSL::Matcher
    def self.flash_message_matcher(expected_type, expected_message)
      match do |page|
        next false unless page.has_css?("#flash-#{expected_type}")
        actual_message = page.find_by_id("flash-#{expected_type}").text
        if expected_message.is_a?(String)
          actual_message == expected_message
        else
          actual_message =~ expected_message
        end
      end

      failure_message do |page|
        <<~MESSAGE
          #{"expected: ".rjust(16)}#{expected_type} - #{expected_message}
          #{"actual error: ".rjust(16)}#{page.has_css?("#flash-error") ? page.find_by_id("flash-error").text : "(no error message)"}
          #{"actual notice: ".rjust(16)}#{page.has_css?("#flash-notice") ? page.find_by_id("flash-notice").text : "(no notice message)"}
        MESSAGE
      end
    end
  end

  RSpec::Matchers.define :have_flash_notice do |expected_message|
    flash_message_matcher(:notice, expected_message)
  end

  RSpec::Matchers.define :have_flash_error do |expected_message|
    flash_message_matcher(:error, expected_message)
  end

  config.include(Module.new do
    def login(email = TEST_USER_EMAIL, password = TEST_USER_PASSWORD)
      visit "/login"
      fill_in "Email Address", with: email
      fill_in "Password", with: password
      click_button "Sign in"

      expect(page.title).to end_with("Dashboard")
    end
  end)
end
