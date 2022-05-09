ENV["RACK_ENV"] = "test"
require_relative '../../models'
raise "test database doesn't end with test" unless DB.opts[:database] =~ /test\z/

Sequel::Model.freeze_descendents
DB.freeze

require_relative '../minitest_helper'
