# frozen_string_literal: true

class Clover
  ubi_version = File.read(File.expand_path("../../../cli/version.txt", __FILE__)).chomp.freeze

  hash_branch(:project_prefix, "cli") do |r|
    r.web do
      r.is do
        no_authorization_needed

        r.get do
          view "cli"
        end

        r.post do
          no_audit_log

          if (multi_cli = typecast_body_params.nonempty_str("multi-cli"))
            multi_cli = multi_cli.split(/\r?\n/)
            multi_cli.reject!(&:empty?)
            @last_cli, @cli, *@clis = multi_cli
          else
            @last_cli = typecast_body_params.str!("cli")
            r.POST.delete("cli")

            if (@clis = typecast_body_params.array(:nonempty_str, "clis"))
              @cli = @clis.shift
            end

            if (confirm = typecast_body_params.nonempty_str("confirm"))
              @last_cli = "--confirm #{confirm.inspect} #{@last_cli}"
            end
          end

          @last_cli = @last_cli.sub(/\A\s*ubi\s+/, "")
          begin
            argv = @last_cli.shellsplit
          rescue ArgumentError => ex
            @repeat_cli = @no_last_cli = true
            flash.now["error"] = "Unable to parse CLI command: #{ex.message}"
            next view "cli"
          end

          env["clover.project_id"] = @project.id
          env["clover.project_ubid"] = @project.ubid
          env["clover.web_cli_session_id"] = rodauth.session_value
          env["HTTP_X_UBI_VERSION"] = ubi_version
          env["CONTENT_TYPE"] = "application/json"

          # Need to save the host and restore it afterward for rack-test to work correctly
          host = env["HTTP_HOST"]
          env["HTTP_HOST"] = "api.ubicloud.com"
          _, headers, body = UbiCli.process(argv, env)
          env["HTTP_HOST"] = host

          body = body.join
          @output = if (@ubi_command_execute = headers["ubi-command-execute"])
            h("$ #{body.split("\0").prepend(@ubi_command_execute).shelljoin}")
          else
            ubids = {}
            body.scan(UbiCli::OBJECT_INFO_REGEXP) do
              if (uuid = UBID.to_uuid(it[0]))
                ubids[uuid] ||= nil
              end
            end
            UBID.resolve_map(ubids)
            h(body).gsub(UbiCli::OBJECT_INFO_REGEXP) do
              if (obj = ubids[UBID.to_uuid(it)]) && obj.respond_to?(:path)
                "<a class=\"text-orange-600\" href=\"#{@project.path}#{obj.path}\">#{it}</a>"
              else
                it
              end
            end
          end

          @repeat_cli = @ubi_confirm = headers["ubi-confirm"]
          view "cli"
        end
      end
    end
  end
end
