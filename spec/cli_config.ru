# frozen_string_literal: true

require "roda"

c = Class.new(Roda) do
  plugin :json_parser

  # When debugging
  # plugin :hooks
  # after do |res|
  #   p res
  # end

  route do |r|
    r.post "cli" do
      unless env["HTTP_AUTHORIZATION"] == "Bearer: a"
        response.status = 400
        next "invalid token\n"
      end

      argv = r.POST["argv"]
      response["content-type"] = "text/plain"

      case argv[0]
      when "version"
        r.env["HTTP_X_UBI_VERSION"]
      when "--confirm"
        case argv[1]
        when "valid"
          "valid-confirm: #{argv[3..].join(" ")}"
        when "invalid"
          response.status = 400
          "invalid-confirm: #{argv[3..].join(" ")}\n"
        when "recurse"
          response["ubi-confirm"] = "Test-Confirm-Recurse"
          ""
        end
      when "confirm"
        response["ubi-confirm"] = "Test-Confirm-Prompt"
        "Pre-Confirm"
      when "exec"
        response["ubi-command-execute"] = argv[1]
        rest = argv[3..]
        case argv[2]
        when "as-is"
          # nothing
        when "psql"
          response["ubi-pgpassword"] = "test-pg-pass"
          rest << "--" << "new"
        when "prog-switch"
          response["ubi-command-execute"] = "new"
          rest << "--"
        when "dash2"
          rest << "--"
        when "new-before"
          rest << "new" << "--"
        when "new-after"
          rest << "--" << "new"
        when "new2"
          rest << "--" << "new" << "new"
        when "newd"
          rest << "-dnew"
        end
        rest.join("\0")
      when "error"
        response.status = 400
        argv.join(" ") << "\n"
      when "headers"
        env.values_at(*%w[HTTP_CONNECTION CONTENT_TYPE HTTP_ACCEPT HTTP_AUTHORIZATION]).join(" ")
      else
        argv.join(" ")
      end
    end
  end
end

run c.freeze.app
