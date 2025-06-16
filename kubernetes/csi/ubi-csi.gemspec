# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "ubi-csi"
  spec.version = "0.1.0"
  spec.authors = ["Ubicloud"]
  spec.email = ["support@ubicloud.com"]

  spec.summary = "Ubicloud CSI Driver"
  spec.description = "Container Storage Interface driver for Ubicloud"
  spec.homepage = "https://github.com/ubicloud/ubicloud"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.files = Dir["lib/**/*", "bin/**/*"]
  spec.bindir = "bin"
  spec.executables = ["ubi-csi-server"]
  spec.require_paths = ["lib"]

  spec.add_dependency "grpc", "~> 1.73"
  spec.add_dependency "grpc-tools", "~> 1.73"
end
