require_relative ".env"
require "zeitwerk"
LOADER = Zeitwerk::Loader.new
LOADER.push_dir("#{__dir__}/")
LOADER.push_dir("#{__dir__}/models")
LOADER.push_dir("#{__dir__}/lib")
LOADER.inflector.inflect("db" => "DB")
LOADER.enable_reloading
LOADER.setup
