# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.configure do |config|
  config.before {
    allow(Config).to receive(:clover_runtime_token_secret).and_return(Config.clover_session_secret)
  }

  config.include(Module.new do
    def login_runtime(vm)
      header "Authorization", "Bearer #{vm.runtime_token}"
    end
  end)
end
