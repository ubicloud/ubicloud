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
Loader.ignore("#{__dir__}/model.rb")
Loader.inflector.inflect("db" => "DB")
Loader.enable_reloading
Loader.setup
