# frozen_string_literal: true

UbiCli.on("app").run_on("show") do
  desc "Show app group status"

  run do
    ap = sdk_object.info
    body = []

    format_uptime = ->(iso_str) {
      begin
        created = Time.parse(iso_str)
        seconds = Time.now - created
        if seconds < 60
          "#{seconds.to_i}s"
        elsif seconds < 3600
          "#{(seconds / 60).to_i}m"
        elsif seconds < 86400
          "#{(seconds / 3600).to_i}h"
        else
          "#{(seconds / 86400).to_i}d"
        end
      rescue
        ""
      end
    }

    display_width = 70

    processes = ap[:processes] || [ap]

    # Header line: group_name vN  (right-aligned) location
    release_num = ap[:release_number]
    group = ap.group_name
    location = ap.location
    if release_num
      left = "#{group} v#{release_num}"
    else
      left = group
    end
    padding = [display_width - left.length - location.length, 2].max
    body << "#{left}#{" " * padding}#{location}\n"

    processes.each do |proc|
      body << "\n"
      subnet = proc[:subnet]
      connected = proc[:connected_subnets] || []
      lb_name = proc[:lb_name]

      # Subnet header line
      header_left = "  #{subnet}"
      if connected.any?
        header_left += " \u2192 #{connected.join(", ")}"
      end

      if lb_name
        lb_display = "lb:#{lb_name}"
        padding = [display_width - header_left.length - lb_display.length, 2].max
        body << "#{header_left}#{" " * padding}#{lb_display}\n"
      else
        body << "#{header_left}\n"
      end

      has_lb = !lb_name.nil?
      members = proc[:members] || []

      # Compute VM name column width from all VMs in this process
      all_vm_names = members.map { |m| m[:vm_name] || "unknown" }
      aliens = proc[:aliens] || []
      all_vm_names += aliens.map { |a| a[:vm_name] || "unknown" }
      name_width = [(all_vm_names.map(&:length).max || 6) + 1, 11].max

      # Per-VM lines (members)
      members.each do |m|
        vm_name = m[:vm_name] || "unknown"
        healthy = m[:healthy]
        created_at = m[:created_at]
        boot_image = m[:boot_image]
        init_tags = m[:init_tags] || []
        lb_health = m[:lb_health]

        health_icon = healthy ? "\u2713" : "\u2717"
        uptime_str = created_at ? format_uptime.call(created_at) : ""

        # Build annotation string: image + init tags
        umi_ref = proc[:umi_ref]
        annotations = []
        if umi_ref
          annotations << umi_ref
        elsif boot_image
          annotations << boot_image
        end
        init_tags.each { |t| annotations << t[:ref] }
        anno_str = annotations.join("  ")

        line = "    #{vm_name.ljust(name_width)}#{health_icon}  #{uptime_str.rjust(3)}  #{anno_str}"

        # LB health column (right side, at least 2 spaces before icon)
        if has_lb && lb_health
          lb_icon = case lb_health
          when "healthy" then "\u2713"
          when "unhealthy" then "\u2717"
          when "drained" then "\u2013"
          else ""
          end
          line += "  #{lb_icon}"
        end

        body << line.rstrip << "\n"
      end

      # Alien separator and alien VMs
      if aliens.any?
        body << "    \u00b7\n"
        aliens.each do |alien|
          vm_name = alien[:vm_name] || "unknown"
          healthy = alien[:healthy]
          created_at = alien[:created_at]
          boot_image = alien[:boot_image]
          init_tags = alien[:init_tags] || []

          health_icon = healthy ? "\u2713" : "\u2717"
          uptime_str = created_at ? format_uptime.call(created_at) : ""

          annotations = []
          annotations << boot_image if boot_image
          init_tags.each { |t| annotations << t[:ref] }
          anno_str = annotations.join("  ")

          line = "    #{vm_name.ljust(name_width)}#{health_icon}  #{uptime_str.rjust(3)}  #{anno_str}"
          body << line.rstrip << "\n"
        end
      end

      # Empty slot brackets
      empty_slots = proc[:empty_slots] || 0
      if empty_slots > 0
        # Build template string from process type's current state
        template_parts = []
        umi_ref = proc[:umi_ref]
        template_parts << umi_ref if umi_ref
        proc_init_tags = proc[:init_tags] || []
        proc_init_tags.each { |t| template_parts << t[:ref] }
        template_str = template_parts.join("  ")

        empty_slots.times do
          if template_str.empty?
            body << "    []\n"
          else
            # Align template with the annotation column of VM lines
            # [ + name_width(padding) + health_icon(1) + 2 + uptime(3) + 2 = annotation start
            inner_pad = name_width + 8
            inner = "#{" " * inner_pad}#{template_str}"
            body << "    [#{inner}]\n"
          end
        end
      end
    end

    response(body)
  end
end
