# frozen_string_literal: true

UbiRodish = Rodish.processor do
  options("ubi [options] [subcommand [subcommand_options] ...]") do
    on("--version", "show program version") { halt "0.0.0" }
    on("--help", "show program help") { halt to_s }
  end
end

Unreloader.record_dependency("lib/rodish.rb", __FILE__)
