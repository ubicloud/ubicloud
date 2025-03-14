=begin
#Clover API

#API for managing resources on Ubicloud

The version of the OpenAPI document: 0.1.0
Contact: support@ubicloud.com
Generated by: https://openapi-generator.tech
Generator version: 7.12.0

=end

require 'date'
require 'time'

module Ubicloud
  class Vm
    # ID of the VM
    attr_accessor :id

    # IPv4 address
    attr_accessor :ip4

    # Whether IPv4 is enabled
    attr_accessor :ip4_enabled

    # IPv6 address
    attr_accessor :ip6

    # Location of the VM
    attr_accessor :location

    # Name of the VM
    attr_accessor :name

    # Size of the underlying VM
    attr_accessor :size

    # State of the VM
    attr_accessor :state

    # Storage size in GiB
    attr_accessor :storage_size_gib

    # Unix user of the VM
    attr_accessor :unix_user

    # Attribute mapping from ruby-style variable name to JSON key.
    def self.attribute_map
      {
        :'id' => :'id',
        :'ip4' => :'ip4',
        :'ip4_enabled' => :'ip4_enabled',
        :'ip6' => :'ip6',
        :'location' => :'location',
        :'name' => :'name',
        :'size' => :'size',
        :'state' => :'state',
        :'storage_size_gib' => :'storage_size_gib',
        :'unix_user' => :'unix_user'
      }
    end

    # Returns attribute mapping this model knows about
    def self.acceptable_attribute_map
      attribute_map
    end

    # Returns all the JSON keys this model knows about
    def self.acceptable_attributes
      acceptable_attribute_map.values
    end

    # Attribute type mapping.
    def self.openapi_types
      {
        :'id' => :'String',
        :'ip4' => :'String',
        :'ip4_enabled' => :'Boolean',
        :'ip6' => :'String',
        :'location' => :'String',
        :'name' => :'String',
        :'size' => :'String',
        :'state' => :'String',
        :'storage_size_gib' => :'Integer',
        :'unix_user' => :'String'
      }
    end

    # List of attributes with nullable: true
    def self.openapi_nullable
      Set.new([
        :'ip4',
        :'ip6',
      ])
    end

    # Initializes the object
    # @param [Hash] attributes Model attributes in the form of hash
    def initialize(attributes = {})
      if (!attributes.is_a?(Hash))
        fail ArgumentError, "The input argument (attributes) must be a hash in `Ubicloud::Vm` initialize method"
      end

      # check to see if the attribute exists and convert string to symbol for hash key
      acceptable_attribute_map = self.class.acceptable_attribute_map
      attributes = attributes.each_with_object({}) { |(k, v), h|
        if (!acceptable_attribute_map.key?(k.to_sym))
          fail ArgumentError, "`#{k}` is not a valid attribute in `Ubicloud::Vm`. Please check the name to make sure it's valid. List of attributes: " + acceptable_attribute_map.keys.inspect
        end
        h[k.to_sym] = v
      }

      if attributes.key?(:'id')
        self.id = attributes[:'id']
      else
        self.id = nil
      end

      if attributes.key?(:'ip4')
        self.ip4 = attributes[:'ip4']
      else
        self.ip4 = nil
      end

      if attributes.key?(:'ip4_enabled')
        self.ip4_enabled = attributes[:'ip4_enabled']
      else
        self.ip4_enabled = nil
      end

      if attributes.key?(:'ip6')
        self.ip6 = attributes[:'ip6']
      else
        self.ip6 = nil
      end

      if attributes.key?(:'location')
        self.location = attributes[:'location']
      else
        self.location = nil
      end

      if attributes.key?(:'name')
        self.name = attributes[:'name']
      else
        self.name = nil
      end

      if attributes.key?(:'size')
        self.size = attributes[:'size']
      else
        self.size = nil
      end

      if attributes.key?(:'state')
        self.state = attributes[:'state']
      else
        self.state = nil
      end

      if attributes.key?(:'storage_size_gib')
        self.storage_size_gib = attributes[:'storage_size_gib']
      else
        self.storage_size_gib = nil
      end

      if attributes.key?(:'unix_user')
        self.unix_user = attributes[:'unix_user']
      else
        self.unix_user = nil
      end
    end

    # Show invalid properties with the reasons. Usually used together with valid?
    # @return Array for valid properties with the reasons
    def list_invalid_properties
      warn '[DEPRECATED] the `list_invalid_properties` method is obsolete'
      invalid_properties = Array.new
      if @id.nil?
        invalid_properties.push('invalid value for "id", id cannot be nil.')
      end

      pattern = Regexp.new(/^vm[0-9a-hj-km-np-tv-z]{24}$/)
      if @id !~ pattern
        invalid_properties.push("invalid value for \"id\", must conform to the pattern #{pattern}.")
      end

      if @ip4_enabled.nil?
        invalid_properties.push('invalid value for "ip4_enabled", ip4_enabled cannot be nil.')
      end

      if @location.nil?
        invalid_properties.push('invalid value for "location", location cannot be nil.')
      end

      if @name.nil?
        invalid_properties.push('invalid value for "name", name cannot be nil.')
      end

      if @size.nil?
        invalid_properties.push('invalid value for "size", size cannot be nil.')
      end

      if @state.nil?
        invalid_properties.push('invalid value for "state", state cannot be nil.')
      end

      if @storage_size_gib.nil?
        invalid_properties.push('invalid value for "storage_size_gib", storage_size_gib cannot be nil.')
      end

      if @unix_user.nil?
        invalid_properties.push('invalid value for "unix_user", unix_user cannot be nil.')
      end

      invalid_properties
    end

    # Check to see if the all the properties in the model are valid
    # @return true if the model is valid
    def valid?
      warn '[DEPRECATED] the `valid?` method is obsolete'
      return false if @id.nil?
      return false if @id !~ Regexp.new(/^vm[0-9a-hj-km-np-tv-z]{24}$/)
      return false if @ip4_enabled.nil?
      return false if @location.nil?
      return false if @name.nil?
      return false if @size.nil?
      return false if @state.nil?
      return false if @storage_size_gib.nil?
      return false if @unix_user.nil?
      true
    end

    # Custom attribute writer method with validation
    # @param [Object] id Value to be assigned
    def id=(id)
      if id.nil?
        fail ArgumentError, 'id cannot be nil'
      end

      pattern = Regexp.new(/^vm[0-9a-hj-km-np-tv-z]{24}$/)
      if id !~ pattern
        fail ArgumentError, "invalid value for \"id\", must conform to the pattern #{pattern}."
      end

      @id = id
    end

    # Custom attribute writer method with validation
    # @param [Object] ip4_enabled Value to be assigned
    def ip4_enabled=(ip4_enabled)
      if ip4_enabled.nil?
        fail ArgumentError, 'ip4_enabled cannot be nil'
      end

      @ip4_enabled = ip4_enabled
    end

    # Custom attribute writer method with validation
    # @param [Object] location Value to be assigned
    def location=(location)
      if location.nil?
        fail ArgumentError, 'location cannot be nil'
      end

      @location = location
    end

    # Custom attribute writer method with validation
    # @param [Object] name Value to be assigned
    def name=(name)
      if name.nil?
        fail ArgumentError, 'name cannot be nil'
      end

      @name = name
    end

    # Custom attribute writer method with validation
    # @param [Object] size Value to be assigned
    def size=(size)
      if size.nil?
        fail ArgumentError, 'size cannot be nil'
      end

      @size = size
    end

    # Custom attribute writer method with validation
    # @param [Object] state Value to be assigned
    def state=(state)
      if state.nil?
        fail ArgumentError, 'state cannot be nil'
      end

      @state = state
    end

    # Custom attribute writer method with validation
    # @param [Object] storage_size_gib Value to be assigned
    def storage_size_gib=(storage_size_gib)
      if storage_size_gib.nil?
        fail ArgumentError, 'storage_size_gib cannot be nil'
      end

      @storage_size_gib = storage_size_gib
    end

    # Custom attribute writer method with validation
    # @param [Object] unix_user Value to be assigned
    def unix_user=(unix_user)
      if unix_user.nil?
        fail ArgumentError, 'unix_user cannot be nil'
      end

      @unix_user = unix_user
    end

    # Checks equality by comparing each attribute.
    # @param [Object] Object to be compared
    def ==(o)
      return true if self.equal?(o)
      self.class == o.class &&
          id == o.id &&
          ip4 == o.ip4 &&
          ip4_enabled == o.ip4_enabled &&
          ip6 == o.ip6 &&
          location == o.location &&
          name == o.name &&
          size == o.size &&
          state == o.state &&
          storage_size_gib == o.storage_size_gib &&
          unix_user == o.unix_user
    end

    # @see the `==` method
    # @param [Object] Object to be compared
    def eql?(o)
      self == o
    end

    # Calculates hash code according to all attributes.
    # @return [Integer] Hash code
    def hash
      [id, ip4, ip4_enabled, ip6, location, name, size, state, storage_size_gib, unix_user].hash
    end

    # Builds the object from hash
    # @param [Hash] attributes Model attributes in the form of hash
    # @return [Object] Returns the model itself
    def self.build_from_hash(attributes)
      return nil unless attributes.is_a?(Hash)
      attributes = attributes.transform_keys(&:to_sym)
      transformed_hash = {}
      openapi_types.each_pair do |key, type|
        if attributes.key?(attribute_map[key]) && attributes[attribute_map[key]].nil?
          transformed_hash["#{key}"] = nil
        elsif type =~ /\AArray<(.*)>/i
          # check to ensure the input is an array given that the attribute
          # is documented as an array but the input is not
          if attributes[attribute_map[key]].is_a?(Array)
            transformed_hash["#{key}"] = attributes[attribute_map[key]].map { |v| _deserialize($1, v) }
          end
        elsif !attributes[attribute_map[key]].nil?
          transformed_hash["#{key}"] = _deserialize(type, attributes[attribute_map[key]])
        end
      end
      new(transformed_hash)
    end

    # Deserializes the data based on type
    # @param string type Data type
    # @param string value Value to be deserialized
    # @return [Object] Deserialized data
    def self._deserialize(type, value)
      case type.to_sym
      when :Time
        Time.parse(value)
      when :Date
        Date.parse(value)
      when :String
        value.to_s
      when :Integer
        value.to_i
      when :Float
        value.to_f
      when :Boolean
        if value.to_s =~ /\A(true|t|yes|y|1)\z/i
          true
        else
          false
        end
      when :Object
        # generic object (usually a Hash), return directly
        value
      when /\AArray<(?<inner_type>.+)>\z/
        inner_type = Regexp.last_match[:inner_type]
        value.map { |v| _deserialize(inner_type, v) }
      when /\AHash<(?<k_type>.+?), (?<v_type>.+)>\z/
        k_type = Regexp.last_match[:k_type]
        v_type = Regexp.last_match[:v_type]
        {}.tap do |hash|
          value.each do |k, v|
            hash[_deserialize(k_type, k)] = _deserialize(v_type, v)
          end
        end
      else # model
        # models (e.g. Pet) or oneOf
        klass = Ubicloud.const_get(type)
        klass.respond_to?(:openapi_any_of) || klass.respond_to?(:openapi_one_of) ? klass.build(value) : klass.build_from_hash(value)
      end
    end

    # Returns the string representation of the object
    # @return [String] String presentation of the object
    def to_s
      to_hash.to_s
    end

    # to_body is an alias to to_hash (backward compatibility)
    # @return [Hash] Returns the object in the form of hash
    def to_body
      to_hash
    end

    # Returns the object in the form of hash
    # @return [Hash] Returns the object in the form of hash
    def to_hash
      hash = {}
      self.class.attribute_map.each_pair do |attr, param|
        value = self.send(attr)
        if value.nil?
          is_nullable = self.class.openapi_nullable.include?(attr)
          next if !is_nullable || (is_nullable && !instance_variable_defined?(:"@#{attr}"))
        end

        hash[param] = _to_hash(value)
      end
      hash
    end

    # Outputs non-array value in the form of hash
    # For object, use to_hash. Otherwise, just return the value
    # @param [Object] value Any valid value
    # @return [Hash] Returns the value in the form of hash
    def _to_hash(value)
      if value.is_a?(Array)
        value.compact.map { |v| _to_hash(v) }
      elsif value.is_a?(Hash)
        {}.tap do |hash|
          value.each { |k, v| hash[k] = _to_hash(v) }
        end
      elsif value.respond_to? :to_hash
        value.to_hash
      else
        value
      end
    end

  end

end
