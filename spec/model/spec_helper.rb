ENV["RACK_ENV"] = "test"
require_relative '../../models'
raise "test database doesn't end with test" unless DB.get{current_database{}} =~ /test\z/

require_relative '../minitest_helper'
