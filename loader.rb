# frozen_string_literal: true

require_relative ".env"
require "zeitwerk"
Loader = Zeitwerk::Loader.new
Loader.push_dir("#{__dir__}/")
Loader.push_dir("#{__dir__}/models")
Loader.push_dir("#{__dir__}/lib")
Loader.ignore("#{__dir__}/routes")
Loader.ignore("#{__dir__}/migrate")
Loader.ignore("#{__dir__}/spec")
models_dir = "#{__dir__}/models.rb"
Loader.ignore(models_dir)
Loader.on_dir_autoloaded(models_dir) do
  require_relative "models"
end
Loader.inflector.inflect("db" => "DB")
Loader.enable_reloading
Loader.setup
