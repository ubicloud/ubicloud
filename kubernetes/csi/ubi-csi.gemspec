# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "ubi-csi"
  spec.version = "0.1.0"
  spec.authors = ["UbiCloud"]
  spec.email = ["info@ubicloud.com"]

  spec.summary = "UbiCloud CSI Driver"
  spec.description = "Container Storage Interface driver for UbiCloud"
  spec.homepage = "https://github.com/ubicloud/ubicloud"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0.0"

  spec.files = Dir["lib/**/*", "bin/**/*"]
  spec.bindir = "bin"
  spec.executables = ["ubi-csi-server"]
  spec.require_paths = ["lib"]

  spec.add_dependency "grpc", "~> 1.54"
  spec.add_dependency "grpc-tools", "~> 1.54"
end
