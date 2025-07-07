# frozen_string_literal: true

module ResourceMethods
  def self.configure(model, etc_type: false, redacted_columns: nil)
    model.instance_exec do
      extend UbidTypeEtcMethods if etc_type
      @ubid_format = /\A#{ubid_type}[a-z0-9]{24}\z/
      @redacted_columns = Array(redacted_columns).freeze
    end
  end

  module UbidTypeEtcMethods
    def ubid_type
      UBID::TYPE_ETC
    end
  end

  module InstanceMethods
    def freeze
      ubid
      super
    end

    def ubid
      @ubid ||= UBID.from_uuidish(id).to_s.downcase
    end

    def to_s
      inspect_prefix
    end

    def inspect_pk
      ubid if id
    end

    def before_validation
      set_uuid
      super
    end

    def set_uuid
      self.id ||= self.class.generate_uuid if new?
      self
    end

    def validate
      super

      if self.class.ubid_format.match?(values[:name])
        errors.add(:name, "cannot be exactly 26 numbers/lowercase characters starting with #{self.class.ubid_type} to avoid overlap with id format")
      end
    end

    INSPECT_CONVERTERS = {
      "uuid" => lambda { |v| UBID.from_uuidish(v).to_s },
      "cidr" => :to_s.to_proc,
      "inet" => :to_s.to_proc,
      "timestamp with time zone" => lambda { |v| v.strftime("%F %T") }
    }.freeze
    def inspect_values
      inspect_values = {}
      sch = db_schema
      @values.except(*self.class.redacted_columns).each do |k, v|
        next if k == :id

        inspect_values[k] = if v
          if (converter = INSPECT_CONVERTERS[sch[k][:db_type]])
            converter.call(v)
          else
            v
          end
        else
          v
        end
      end
      inspect_values.inspect
    end

    NON_ARCHIVED_MODELS = ["ArchivedRecord", "Semaphore"]
    def before_destroy
      model_name = self.class.name
      unless NON_ARCHIVED_MODELS.include?(model_name)
        model_values = values.merge(model_name: model_name)

        encryption_metadata = self.class.instance_variable_get(:@column_encryption_metadata)
        unless encryption_metadata.empty?
          encryption_metadata.keys.each do |key|
            model_values.delete(key)
          end
        end

        ArchivedRecord.create(model_name: model_name, model_values: model_values)
      end

      super
    end
  end

  module ClassMethods
    attr_reader :ubid_format

    # Adapted from sequel/model/inflections.rb's underscore, to convert
    # class names into symbols
    def self.uppercase_underscore(s)
      s.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2').gsub(/([a-z\d])([A-Z])/, '\1_\2').tr("-", "_").upcase
    end

    def [](arg)
      if arg.is_a?(UBID)
        super(arg.to_uuid)
      elsif arg.is_a?(String) && arg.bytesize == 26
        begin
          ubid = UBID.parse(arg)
        rescue UBIDParseError
          super
        else
          super(ubid.to_uuid)
        end
      else
        super
      end
    end

    def ubid_type
      UBID.const_get("TYPE_#{ClassMethods.uppercase_underscore(name)}")
    end

    def generate_ubid
      UBID.generate(ubid_type)
    end

    def generate_uuid
      generate_ubid.to_uuid
    end

    def new_with_id(...)
      new(...).set_uuid
    end

    def create_with_id(...)
      create(...)
    end

    def redacted_columns
      (column_encryption_metadata.keys || []) + @redacted_columns
    end
  end
end
