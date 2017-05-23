ENV["RACK_ENV"] = "test"
require_relative '../../app'
raise "test database doesn't end with test" unless DB.opts[:database] =~ /test\z/

require 'capybara'
require 'capybara/dsl'
require 'rack/test'

require_relative '../minitest_helper'

Capybara.app = App.freeze

class Minitest::Spec
  include Rack::Test::Methods
  include Capybara::DSL
end
