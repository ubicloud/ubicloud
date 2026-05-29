# frozen_string_literal: true

class UbiCli
  on("version") do
    desc "Display CLI program version"

    banner "ubi version"

    run do
      response(client_version)
    end
  end
end
