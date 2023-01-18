# Adapted from https://github.com/interagent/pliny/blob/fcc8f3b103ec5296bd754898fdefeb2fda2ab292/lib/pliny/config_helpers.rb
#
# It is MIT licensed.
module CastingConfigHelpers
  def mandatory(name, method = nil, clear: false)
    env_name = name.to_s.upcase
    value = cast(ENV.fetch(env_name), method)
    create(name, value)
    ENV.delete(env_name) if clear
  end

  def optional(name, method = nil)
    value = cast(ENV[name.to_s.upcase], method)
    create(name, value)
  end

  def override(name, default, method = nil)
    value = cast(ENV.fetch(name.to_s.upcase, default), method)
    create(name, value)
  end

  def int
    ->(v) { v.to_i }
  end

  def float
    ->(v) { v.to_f }
  end

  def bool
    ->(v) { v.to_s == "true" }
  end

  def string
    nil
  end

  def symbol
    ->(v) { v.to_sym }
  end

  # optional :accronyms, array(string)
  # => ['a', 'b']
  # optional :numbers, array(int)
  # => [1, 2]
  # optional :notype, array
  # => ['a', 'b']
  def array(method = nil)
    ->(v) do
      v&.split(",")&.map { |a| cast(a, method) }
    end
  end

  def rack_env
    if env == "development" || env == "test"
      "development"
    else
      "deployment"
    end
  end

  # DEPRECATED: pliny_env is deprecated in favour of app_env.
  #             See more at https://github.com/interagent/pliny/issues/277
  #
  # This method is kept temporary in case it is used somewhere in the app.
  def pliny_env
    warn "Config.pliny_env is deprecated and will be removed, " \
         "use Config.app_env instead."
    env
  end

  private

  def cast(value, method)
    method ? method.call(value) : value
  end

  def create(name, value)
    instance_variable_set(:"@#{name}", value)
    instance_eval "def #{name}; @#{name} end", __FILE__, __LINE__
    if value.is_a?(TrueClass) || value.is_a?(FalseClass) || value.is_a?(NilClass)
      instance_eval "def #{name}?; !!@#{name} end", __FILE__, __LINE__
    end
  end

  # This method helps with transition from PLINY_ENV to APP_ENV.
  def env
    legacy_env || app_env
  end

  # PLINY_ENV is deprecated, but it might be still used by someone.
  def legacy_env
    if ENV.key?("PLINY_ENV")
      warn "PLINY_ENV is deprecated in favour of APP_ENV, " \
           "update .env file or application configuration."
      ENV["PLINY_ENV"]
    end
  end
end
