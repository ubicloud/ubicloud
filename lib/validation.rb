# frozen_string_literal: true

require "time"
require "netaddr"
require "excon"

module Validation
  class ValidationFailed < CloverError
    def initialize(details)
      super(400, "InvalidRequest", "Validation failed for following fields: #{details.keys.join(", ")}", details)
    end
  end

  # Allow DNS compatible names
  # - Max length 63
  # - Only lowercase letters, numbers, and hyphens
  # - Not start or end with a hyphen
  # Adapted from https://stackoverflow.com/a/7933253
  # Do not allow uppercase letters to not deal with case sensitivity
  ALLOWED_NAME_PATTERN = %r{\A[a-z0-9](?:[a-z0-9\-]{0,61}[a-z0-9])?\z}

  # Different operating systems have different conventions.
  # Below are reasonable restrictions that works for most (all?) systems.
  # - Max length 32
  # - Only lowercase letters, numbers, hyphens and underscore
  # - Not start with a hyphen or number
  ALLOWED_OS_USER_NAME_PATTERN = %r{\A[a-z_][a-z0-9_-]{0,31}\z}

  # Minio user name, we are using ALLOWED_OS_USER_NAME_PATTERN with min length of 3
  ALLOWED_MINIO_USERNAME_PATTERN = %r{\A[a-z_][a-z0-9_-]{2,31}\z}

  ALLOWED_PORT_RANGE_PATTERN = %r{\A(\d+)(?:\.\.(\d+))?\z}

  # - Max length 63
  # - Alphanumeric, hyphen, underscore, space, parantheses, exclamation, question mark, star
  ALLOWED_SHORT_TEXT_PATTERN = %r{\A[a-zA-Z0-9_\-!?\*\(\) ]{1,63}\z}

  # - Max length 63
  # - Unicode letters, numbers, hyphen, space
  ALLOWED_ACCOUNT_NAME = %r{\A\p{L}[\p{L}0-9\- ]{1,62}\z}

  def self.validate_name(name)
    msg = "Name must only contain lowercase letters, numbers, and hyphens and have max length 63."
    fail ValidationFailed.new({name: msg}) unless name&.match(ALLOWED_NAME_PATTERN)
  end

  def self.validate_minio_username(username)
    msg = "Minio user must only contain lowercase letters, numbers, hyphens and underscore and cannot start with a number or hyphen. It also have max length of 32, min length of 3."
    fail ValidationFailed.new({username: msg}) unless username&.match(ALLOWED_MINIO_USERNAME_PATTERN)
  end

  def self.validate_location(location)
    available_locs = Option.locations(only_visible: false).map(&:name)
    msg = "Given location is not a valid location. Available locations: #{available_locs.map { LocationNameConverter.to_display_name(_1) }}"
    fail ValidationFailed.new({provider: msg}) unless available_locs.include?(location)
  end

  def self.validate_postgres_location(location)
    available_pg_locs = Option.postgres_locations.map(&:name)
    msg = "Given location is not a valid postgres location. Available locations: #{available_pg_locs.map { LocationNameConverter.to_display_name(_1) }}"
    fail ValidationFailed.new({location: msg}) unless available_pg_locs.include?(location)
  end

  def self.validate_vm_size(size, arch, only_visible: false)
    available_vm_sizes = Option::VmSizes.select { !only_visible || _1.visible }
    unless (vm_size = available_vm_sizes.find { _1.name == size && _1.arch == arch })
      fail ValidationFailed.new({size: "\"#{size}\" is not a valid virtual machine size. Available sizes: #{available_vm_sizes.map(&:name)}"})
    end
    vm_size
  end

  def self.validate_vm_storage_size(size, arch, storage_size)
    storage_size = storage_size.to_i
    vm_size = validate_vm_size(size, arch)
    fail ValidationFailed.new({storage_size: "Storage size must be one of the following: #{vm_size.storage_size_options.join(", ")}"}) unless vm_size.storage_size_options.include?(storage_size)
    storage_size
  end

  def self.validate_boot_image(image_name)
    unless Option::BootImages.find { _1.name == image_name }
      fail ValidationFailed.new({boot_image: "\"#{image_name}\" is not a valid boot image name. Available boot image names are: #{Option::BootImages.map(&:name)}"})
    end
  end

  def self.validate_postgres_ha_type(ha_type)
    unless Option::PostgresHaOptions.find { _1.name == ha_type }
      fail ValidationFailed.new({ha_type: "\"#{ha_type}\" is not a valid PostgreSQL high availability option. Available options: #{Option::PostgresHaOptions.map(&:name)}"})
    end
  end

  def self.validate_postgres_flavor(flavor)
    flavors = [PostgresResource::Flavor::STANDARD, PostgresResource::Flavor::PARADEDB, PostgresResource::Flavor::LANTERN]
    unless flavors.include?(flavor)
      fail ValidationFailed.new({flavor: "\"#{flavor}\" is not a valid PostgreSQL flavor option. Available options: #{flavors}"})
    end
  end

  def self.validate_load_balancer_stack(stack)
    unless [LoadBalancer::Stack::IPV4, LoadBalancer::Stack::IPV6, LoadBalancer::Stack::DUAL].include?(stack)
      fail ValidationFailed.new({stack: "\"#{stack}\" is not a valid load balancer stack option. Available options: #{LoadBalancer::Stack::IPV4}, #{LoadBalancer::Stack::IPV6}, #{LoadBalancer::Stack::DUAL}"})
    end
    stack
  end

  def self.validate_os_user_name(os_user_name)
    msg = "OS user name must only contain lowercase letters, numbers, hyphens and underscore and cannot start with a number or hyphen. It also have max length of 32."
    fail ValidationFailed.new({user: msg}) unless os_user_name&.match(ALLOWED_OS_USER_NAME_PATTERN)
  end

  def self.validate_storage_volumes(storage_volumes, boot_disk_index)
    allowed_keys = [
      :encrypted, :size_gib, :boot, :skip_sync, :read_only, :image,
      :max_ios_per_sec, :max_read_mbytes_per_sec, :max_write_mbytes_per_sec
    ]
    fail ValidationFailed.new({storage_volumes: "At least one storage volume is required."}) if storage_volumes.empty?
    if boot_disk_index < 0 || boot_disk_index >= storage_volumes.length
      fail ValidationFailed.new({boot_disk_index: "Boot disk index must be between 0 and #{storage_volumes.length - 1}"})
    end
    storage_volumes.each { |volume|
      volume.each_key { |key|
        fail ValidationFailed.new({storage_volumes: "Invalid key: #{key}"}) unless allowed_keys.include?(key)
      }
    }
  end

  def self.validate_postgres_size(location, size)
    unless (postgres_size = Option::PostgresSizes.find { _1.location == location && _1.name == size })
      fail ValidationFailed.new({size: "\"#{size}\" is not a valid PostgreSQL database size. Available sizes: #{Option::PostgresSizes.map(&:name)}"})
    end
    postgres_size
  end

  def self.validate_postgres_storage_size(location, size, storage_size)
    storage_size = storage_size.to_i
    pg_size = validate_postgres_size(location, size)
    fail ValidationFailed.new({storage_size: "Storage size must be one of the following: #{pg_size.storage_size_options.join(", ")}"}) unless pg_size.storage_size_options.include?(storage_size)
    storage_size
  end

  def self.validate_date(date, param = "date")
    # I use DateTime.parse instead of Time.parse because it uses UTC as default
    # timezone but Time.parse uses local timezone
    DateTime.parse(date.to_s).to_time
  rescue ArgumentError
    msg = "\"#{date}\" is not a valid date for \"#{param}\"."
    fail ValidationFailed.new({param => msg})
  end

  def self.validate_postgres_superuser_password(original_password, repeat_password = nil)
    messages = []
    messages.push("Password must have 12 characters minimum.") if original_password.size < 12
    messages.push("Password must have at least one lowercase letter.") unless original_password.match?(/[a-z]/)
    messages.push("Password must have at least one uppercase letter.") unless original_password.match?(/[A-Z]/)
    messages.push("Password must have at least one digit.") unless original_password.match?(/[0-9]/)

    repeat_message = "Passwords must match." if repeat_password && original_password != repeat_password

    details = {}
    details["password"] = messages unless messages.empty?
    details["repeat_password"] = repeat_message if repeat_message
    fail ValidationFailed.new(details) unless details.empty?
  end

  def self.validate_cidr(cidr)
    if cidr.include?(".")
      NetAddr::IPv4Net.parse(cidr)
    elsif cidr.include?(":")
      NetAddr::IPv6Net.parse(cidr)
    else
      fail ValidationFailed.new({cidr: "Invalid CIDR"})
    end
  rescue NetAddr::ValidationError
    fail ValidationFailed.new({cidr: "Invalid CIDR"})
  end

  def self.validate_port_range(port_range)
    fail ValidationFailed.new({port_range: "Invalid port range"}) unless (match = port_range.match(ALLOWED_PORT_RANGE_PATTERN))
    start_port = match[1].to_i

    if match[2]
      end_port = match[2].to_i
      fail ValidationFailed.new({port_range: "Start port must be between 0 to 65535"}) unless (0..65535).cover?(start_port)
      fail ValidationFailed.new({port_range: "End port must be between 0 to 65535"}) unless (0..65535).cover?(end_port)
      fail ValidationFailed.new({port_range: "Start port must be smaller than or equal to end port"}) unless start_port <= end_port
    else
      fail ValidationFailed.new({port_range: "Port must be between 0 to 65535"}) unless (0..65535).cover?(start_port)
    end

    end_port ? [start_port, end_port] : [start_port]
  end

  def self.validate_port(port_name, port)
    fail ValidationFailed.new({port_name => "Port must be an integer"}) unless port.to_i.to_s == port.to_s
    fail ValidationFailed.new({port_name => "Port must be between 0 to 65535"}) unless (0..65535).cover?(port.to_i)
    port.to_i
  end

  def self.validate_request_params(request_body_params, required_keys, allowed_optional_keys = [])
    missing_required_keys = required_keys - request_body_params.keys
    unless missing_required_keys.empty?
      fail ValidationFailed.new({body: "Request body must include required parameters: #{missing_required_keys.join(", ")}"})
    end

    allowed_keys = required_keys + allowed_optional_keys
    unallowed_keys = request_body_params.keys - allowed_keys
    if unallowed_keys.any?
      fail ValidationFailed.new({body: "Only following parameters are allowed: #{allowed_keys.join(", ")}"})
    end

    request_body_params
  end

  def self.validate_usage_limit(limit)
    limit_integer = limit.to_i
    fail ValidationFailed.new({limit: "Limit is not a valid integer."}) if limit_integer.to_s != limit
    fail ValidationFailed.new({limit: "Limit must be greater than 0."}) if limit_integer <= 0
    limit_integer
  end

  def self.validate_short_text(text, field_name)
    fail ValidationFailed.new({field_name: "The #{field_name} must have max length 63 and only contain alphanumeric characters, hyphen, underscore, space, parantheses, exclamation, question mark and star."}) unless text.match(ALLOWED_SHORT_TEXT_PATTERN)
  end

  def self.validate_account_name(name)
    fail ValidationFailed.new({name: "Name must only contain letters, numbers, spaces, and hyphens and have max length 63."}) unless name&.match(ALLOWED_ACCOUNT_NAME)
  end

  def self.validate_url(url)
    uri = URI.parse(url)
    fail ValidationFailed.new({url: "Invalid URL scheme. Only https URLs are supported."}) if uri.scheme != "https"
    fail ValidationFailed.new({url: "Invalid URL"}) if uri.host.nil? || uri.host.empty?
  rescue URI::InvalidURIError
    fail ValidationFailed.new({url: "Invalid URL"})
  end

  def self.validate_vcpu_quota(project, resource_type, requested_vcpu_count)
    if !project.quota_available?(resource_type, requested_vcpu_count)
      current_used_vcpu_count = project.current_resource_usage(resource_type)
      effective_quota_value = project.effective_quota_value(resource_type)

      fail ValidationFailed.new({size: "Insufficient quota for requested size. Requested vCPU count: #{requested_vcpu_count}, currently used vCPU count: #{current_used_vcpu_count}, maximum allowed vCPU count: #{effective_quota_value}, remaining vCPU count: #{effective_quota_value - current_used_vcpu_count}"})
    end
  end

  def self.validate_cloudflare_turnstile(cf_response)
    return unless Config.cloudflare_turnstile_site_key

    response = Excon.post("https://challenges.cloudflare.com/turnstile/v0/siteverify",
      headers: {"Content-Type" => "application/x-www-form-urlencoded"},
      body: URI.encode_www_form(secret: Config.cloudflare_turnstile_secret_key, response: cf_response),
      expects: 200)
    response_hash = JSON.parse(response.body)
    unless response_hash["success"]
      Clog.emit("cloudflare turnstile validation failed") { {cf_validation_failed: response_hash["error-codes"]} }
      fail ValidationFailed.new({cloudflare_turnstile: "Validation failed. Please try again."})
    end
  end
end
