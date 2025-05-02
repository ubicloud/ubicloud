# frozen_string_literal: true

UbiCli.on("ai", "api-key").run_on("show") do
  desc "Show details for an inference API key"

  banner "ubi ai api-key api-key-id show"

  run do
    iak = @sdk_object
    body = []
    body << "id: " << iak.id << "\n"
    body << "key: " << iak.key << "\n"
    response(body)
  end
end
