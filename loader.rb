require_relative ".env"
require "zeitwerk"
Loader = Zeitwerk::Loader.new
Loader.push_dir("#{__dir__}/")
Loader.push_dir("#{__dir__}/models")
Loader.push_dir("#{__dir__}/lib")
Loader.ignore("#{__dir__}/routes")
Loader.ignore("#{__dir__}/migrate")
Loader.inflector.inflect("db" => "DB")
Loader.enable_reloading
Loader.setup
