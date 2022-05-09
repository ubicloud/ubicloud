dev = ENV['RACK_ENV'] == 'development'

if dev
  require 'logger'
  logger = Logger.new($stdout)
end

require 'rack/unreloader'
Unreloader = Rack::Unreloader.new(subclasses: %w'Roda Sequel::Model', logger: logger, reload: dev){App}
require_relative 'models'
Unreloader.require('app.rb'){'App'}
run(dev ? Unreloader : App.freeze.app)

freeze_core = false
#freeze_core = !dev # Uncomment to enable refrigerator
if freeze_core
  begin
    require 'refrigerator'
  rescue LoadError
  else
    require 'tilt/sass' unless File.exist?(File.expand_path('../compiled_assets.json', __FILE__))

    # When enabling refrigerator, you may need to load additional
    # libraries before freezing the core to work correctly.  You'll
    # want to uncomment the appropriate lines below if you run into
    # problems after enabling refrigerator.

    # rackup -s webrick
    #require 'forwardable'
    #require 'webrick'

    # rackup -s Puma
    #require 'yaml' 
    #Gem.ruby

    # Puma (needed for state file)
    #require 'yaml'

    # Unicorn (no changes needed)

    Refrigerator.freeze_core
  end
end
