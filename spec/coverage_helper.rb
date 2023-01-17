if suite = ENV.delete('COVERAGE')
  require 'simplecov'

  SimpleCov.start do
    enable_coverage :branch
    command_name suite

    add_filter "/spec/"
    add_filter "/models.rb"
    add_filter "/db.rb"
    add_filter "/.env.rb"
    add_group('Missing'){|src| src.covered_percent < 100}
    add_group('Covered'){|src| src.covered_percent == 100}
  end
end
