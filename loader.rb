# frozen_string_literal: true

require_relative ".env"
require "zeitwerk"
Loader = Zeitwerk::Loader.new
Loader.push_dir("#{__dir__}/")
Loader.push_dir("#{__dir__}/model")
Loader.push_dir("#{__dir__}/lib")
Loader.ignore("#{__dir__}/routes")
Loader.ignore("#{__dir__}/migrate")
Loader.ignore("#{__dir__}/spec")
model_dir = "#{__dir__}/model"
Loader.ignore(model_dir + "/model.rb")
Loader.on_dir_autoloaded(model_dir) do
  require_relative "model"
end
Loader.inflector.inflect("db" => "DB")
Loader.inflector.inflect("cprog" => "CProg")
Loader.enable_reloading
Loader.setup
