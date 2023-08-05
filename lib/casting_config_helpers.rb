# frozen_string_literal: true

require "base64"

# Adapted from https://github.com/interagent/pliny/blob/fcc8f3b103ec5296bd754898fdefeb2fda2ab292/lib/pliny/config_helpers.rb
#
# It is MIT licensed.
module CastingConfigHelpers
  def assign_cast_clear(name, method, clear)
    env_name = name.to_s.upcase
    uncast_value = yield env_name
    create(name, cast(uncast_value, method))
    ENV.delete(env_name) if clear
  end

  def mandatory(name, method = nil, clear: false)
    assign_cast_clear name, method, clear do |env_name|
      ENV.fetch(env_name)
    end
  end

  def optional(name, method = nil, clear: false)
    assign_cast_clear name, method, clear do |env_name|
      ENV[env_name]
    end
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

  def base64
    ->(v) { v && Base64.decode64(v) }
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
end
