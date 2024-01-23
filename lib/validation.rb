# frozen_string_literal: true

require "time"

module Validation
  class ValidationFailed < StandardError
    attr_reader :errors
    def initialize(errors)
      @errors = errors
      super("Validation failed for following fields: #{errors.keys.join(", ")}")
    end
  end

  # Allow DNS compatible names
  # - Max length 63
  # - Only lowercase letters, numbers, and hyphens
  # - Not start or end with a hyphen
  # Adapted from https://stackoverflow.com/a/7933253
  # Do not allow uppercase letters to not deal with case sensitivity
  ALLOWED_NAME_PATTERN = '\A[a-z0-9](?:[a-z0-9\-]{0,61}[a-z0-9])?\z'

  # Different operating systems have different conventions.
  # Below are reasonable restrictions that works for most (all?) systems.
  # - Max length 32
  # - Only lowercase letters, numbers, hyphens and underscore
  # - Not start with a hyphen or number
  ALLOWED_OS_USER_NAME_PATTERN = '\A[a-z_][a-z0-9_-]{0,31}\z'

  # Minio user name, we are using ALLOWED_OS_USER_NAME_PATTERN with min length of 3
  ALLOWED_MINIO_USERNAME_PATTERN = '\A[a-z_][a-z0-9_-]{2,31}\z'

  def self.validate_name(name)
    msg = "Name must only contain lowercase letters, numbers, and hyphens and have max length 63."
    fail ValidationFailed.new({name: msg}) unless name&.match(ALLOWED_NAME_PATTERN)
  end

  def self.validate_minio_username(username)
    msg = "Minio user must only contain lowercase letters, numbers, hyphens and underscore and cannot start with a number or hyphen. It also have max length of 32, min length of 3."
    fail ValidationFailed.new({username: msg}) unless username&.match(ALLOWED_MINIO_USERNAME_PATTERN)
  end

  def self.validate_provider(provider)
    msg = "\"#{provider}\" is not a valid provider. Available providers: #{Option::Providers.keys}"
    fail ValidationFailed.new({provider: msg}) unless Option::Providers.key?(provider)
  end

  def self.validate_location(location, provider = nil)
    available_locs = Option.locations_for_provider(provider, only_visible: false).map(&:name)
    msg = "\"#{location}\" is not a valid location for provider \"#{provider}\". Available locations: #{available_locs}"
    fail ValidationFailed.new({provider: msg}) unless available_locs.include?(location)
  end

  def self.validate_vm_size(size)
    unless (vm_size = Option::VmSizes.find { _1.name == size })
      fail ValidationFailed.new({size: "\"#{size}\" is not a valid virtual machine size. Available sizes: #{Option::VmSizes.map(&:name)}"})
    end
    vm_size
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

  def self.validate_postgres_superuser_password(original_password, repeat_password)
    messages = []
    messages.push("Password must have 12 characters minimum.") if original_password.size < 12
    messages.push("Password must have at least one lowercase letter.") unless original_password.match?(/[a-z]/)
    messages.push("Password must have at least one uppercase letter.") unless original_password.match?(/[A-Z]/)
    messages.push("Password must have at least one digit.") unless original_password.match?(/[0-9]/)
    messages.push("Passwords must match.") if original_password != repeat_password

    unless messages.empty?
      fail ValidationFailed.new({"original_password" => messages.map { _1 }})
    end
  end
end
