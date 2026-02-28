# frozen_string_literal: true

UbiCli.on("init", "show") do
  desc "Show an init script"

  banner "ubi init show name@version"

  help_example "ubi init show secrets@2"

  args 1

  run do |ref|
    tag = sdk.init_script_tag.new(ref)
    info = tag.info

    size = info[:size].to_i
    size_str = if size >= 1024
      "#{(size / 1024.0).round(1)}K"
    else
      "#{size}B"
    end

    body = []
    body << "#{info[:name]}@#{info[:version]}  #{info[:id]}  #{size_str}  #{info[:created_at]}\n"
    body << "---\n"
    body << info[:content].to_s
    body << "\n" unless info[:content].to_s.end_with?("\n")
    response(body)
  end
end
