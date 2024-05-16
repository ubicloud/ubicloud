# frozen_string_literal: true

require "time"
require "netaddr"

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

  def self.validate_vm_size(size, only_visible: false)
    available_vm_sizes = Option::VmSizes.select { !only_visible || _1.visible }
    unless (vm_size = available_vm_sizes.find { _1.name == size })
      fail ValidationFailed.new({size: "\"#{size}\" is not a valid virtual machine size. Available sizes: #{available_vm_sizes.map(&:name)}"})
    end
    vm_size
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

  def self.validate_os_user_name(os_user_name)
    msg = "OS user name must only contain lowercase letters, numbers, hyphens and underscore and cannot start with a number or hyphen. It also have max length of 32."
    fail ValidationFailed.new({user: msg}) unless os_user_name&.match(ALLOWED_OS_USER_NAME_PATTERN)
  end

  def self.validate_storage_volumes(storage_volumes, boot_disk_index)
    allowed_keys = [:encrypted, :size_gib, :boot, :skip_sync]
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

  def self.validate_postgres_size(size)
    unless (postgres_size = Option::PostgresSizes.find { _1.name == size })
      fail ValidationFailed.new({size: "\"#{size}\" is not a valid PostgreSQL database size. Available sizes: #{Option::PostgresSizes.map(&:name)}"})
    end
    postgres_size
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
    messages.push("Passwords must match.") if repeat_password && original_password != repeat_password

    unless messages.empty?
      if repeat_password
        fail ValidationFailed.new({"original_password" => messages.map { _1 }})
      else
        fail ValidationFailed.new({"password" => messages.map { _1 }})
      end
    end
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

  def self.validate_request_body(request_body, required_keys, allowed_optional_keys = [])
    begin
      request_body_params = JSON.parse(request_body)
    rescue JSON::ParserError
      fail ValidationFailed.new({body: "Request body isn't a valid JSON object."})
    end

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
end
