# frozen_string_literal: true

UbiCli.on("app").run_on("add") do
  desc "Add VMs to an app process (claim existing or create new)"

  banner "ubi app (location/app-name | app-id) add [vm-name ...]"

  args(0..)

  run do |vm_names|
    if vm_names.empty?
      result = sdk_object.add
      body = ["#{result.name}  1 VM created\n"]
      members = result[:members] || []
      newest = members.max_by { it[:ordinal] }
      if newest
        body << "  #{newest[:vm_name]}  ordinal=#{newest[:ordinal]}\n"
      end
    else
      result = sdk_object.add(vm_names: vm_names)
      body = ["#{result.name}  #{vm_names.size} VM#{"s" if vm_names.size > 1} added\n"]

      members = result[:members] || []
      health = result[:health_count] || 0
      total = result[:total_count] || 0
      label = result[:health_label] || "healthy"

      vm_lines = members.select { vm_names.include?(it[:vm_name]) }
      names_str = vm_lines.map { it[:vm_name] }.join("  ")
      body << "  #{names_str}  (#{health}/#{total} #{label})\n"
    end

    response(body)
  end
end
