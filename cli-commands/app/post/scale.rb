# frozen_string_literal: true

UbiCli.on("app").run_on("scale") do
  desc "Set desired VM count for an app process"

  banner "ubi app (location/app-name | app-id) scale N"

  args 1

  run do |count_str, cmd|
    count = Integer(count_str) rescue nil
    raise Rodish::CommandFailure.new("scale requires a positive integer", cmd) unless count && count > 0

    result = sdk_object.scale(count: count)
    desired = result[:desired_count] || count
    actual = (result[:members] || []).size
    body = ["#{result.name}  desired=#{desired} actual=#{actual}\n"]

    if desired > actual
      body << "  #{desired - actual} VM#{"s" if desired - actual != 1} being created\n"
    end

    response(body)
  end
end
