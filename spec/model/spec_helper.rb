require_relative '../coverage_helper'
ENV["RACK_ENV"] = "test"
require_relative '../../models'
raise "test database doesn't end with test" if DB.opts[:database] && !DB.opts[:database].end_with?('test')

Sequel::Model.freeze_descendents
DB.freeze

require_relative '../minitest_helper'
