# frozen_string_literal: true

class Clover
  hash_branch(:webhook_prefix, "github") do |r|
    r.post true do
      body = r.body.read
      next 401 unless (signature = r.headers["x-hub-signature-256"])
      expected_signature = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", Config.github_app_webhook_secret, body)}"
      next 401 unless Rack::Utils.secure_compare(signature, expected_signature)

      response.content_type = :json

      data = JSON.parse(body)
      case r.headers["x-github-event"]
      when "installation"
        handle_webhook_github_installation(data)
      when "workflow_job"
        handle_webhook_github_workflow_job(data)
      else
        {error: {message: "Unhandled event"}}
      end
    end
  end
end
