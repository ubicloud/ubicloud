# frozen_string_literal: true

UbiCli.on("app").run_on("set") do
  desc "Set image, init scripts, or VM size on an app process"

  options("ubi app location/app-name set [options]", key: :app_set) do
    on("--umi=ref", "UMI reference (e.g., mastodon@4.6.0)")
    on("--init=x,y", Array, "Init script refs: name@version or name=./path (comma-separated)")
    on("--size=size", "VM size for new VMs")
    on("--from=version", "Re-release from a previous release (e.g., v5)")
    on("--keep=x,y", Array, "Keep current version of these inits when using --from (comma-separated)")
  end

  run do |opts, cmd|
    params = opts[:app_set] || {}

    umi = params[:umi]
    vm_size = params[:size]
    init = params[:init]
    from = params[:from]
    keep = params[:keep]

    unless umi || vm_size || init || from
      raise Rodish::CommandFailure.new("at least one of --umi, --init, --size, or --from is required", cmd)
    end

    if keep && !from
      raise Rodish::CommandFailure.new("--keep can only be used with --from", cmd)
    end

    # For push-and-set (name=./path), read file content and send as name=content.
    # A path is detected by containing "/" or starting with ".".
    resolved_init = init&.map do |ref|
      if ref.match?(/\A[^@=]+=\./) || ref.match?(/\A[^@=]+=\//)
        name, path = ref.split("=", 2)
        content = File.read(path)
        "#{name}=#{content}"
      else
        ref
      end
    end

    result = sdk_object.set(umi: umi, vm_size: vm_size, init: resolved_init, from: from, keep: keep)

    body = []

    # Show push results
    if result[:push_results]
      result[:push_results].each do |pr|
        if pr[:unchanged]
          body << "#{pr[:name]}@#{pr[:version]}  (unchanged, content matches latest)\n"
        else
          body << "#{pr[:name]}@#{pr[:version]}  pushed\n"
        end
      end
    end

    # Show release line if template changed (umi, init, or from)
    template_changed = umi || init || from
    if template_changed && result[:release_number]
      init_tags = result[:init_tags] || []
      init_str = init_tags.map { |t| "#{t[:name]}@#{t[:version]}" }.join("  ")
      parts = ["v#{result[:release_number]}: #{result[:process_name]}"]
      parts << "  #{result[:umi_ref]}" if result[:umi_ref]
      parts << "  #{init_str}" unless init_str.empty?
      body << parts.join + "\n"
    else
      body << "#{result[:name]}  updated\n"
      body << "  umi: #{result[:umi_ref]}\n" if result[:umi_ref]
      body << "  vm size: #{result[:vm_size]}\n" if result[:vm_size]
      init_tags = result[:init_tags] || []
      init_tags.each do |t|
        body << "  init: #{t[:name]}@#{t[:version]}\n"
      end
    end

    response(body)
  end
end
