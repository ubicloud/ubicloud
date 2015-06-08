ENV["RACK_ENV"] = "test"
require_relative '../../app'
raise "test database doesn't end with test" unless DB.get{current_database{}} =~ /test\z/

App.freeze

require 'capybara'
require 'capybara/dsl'
require 'rack/test'

require_relative '../minitest_helper'
