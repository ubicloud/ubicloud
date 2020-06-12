ENV["RACK_ENV"] = "test"
require_relative '../warnings_helper'
require_relative '../../models'
raise "test database doesn't end with test" unless DB.opts[:database] =~ /test\z/

require_relative '../minitest_helper'
