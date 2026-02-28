# frozen_string_literal: true

UbiCli.on("init", "push") do
  desc "Push an init script to the registry"

  banner "ubi init push name content"

  help_example "ubi init push secrets \"$(cat ./secrets.env.sh)\""

  args 2

  run do |name, content|
    result = sdk.init_script_tag.create(name: name, content: content)

    if result[:unchanged]
      response("#{result[:name]}@#{result[:version]}  (unchanged, content matches latest)")
    else
      size = result[:size]
      size_str = if size >= 1024
        "#{(size / 1024.0).round(1)}K"
      else
        "#{size}B"
      end
      response("#{result[:name]}@#{result[:version]}  pushed  #{size_str}")
    end
  end
end
