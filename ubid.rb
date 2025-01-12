# frozen_string_literal: true

require("securerandom")

class UBIDParseError < RuntimeError
end

class UBID
  # Binary format, which is UUIDv8 compatible, is:
  # 0                   1                   2                   3
  #  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
  #  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  #  |                      32_bit_uint_time_high                    |
  #  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  #  |     16_bit_uint_time_low      |  ver  |r_1|  type_1 |  type_2 |
  #  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  #  |var|                         r_2                               |
  #  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  #  |                             r_2                               |
  #  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  #
  # String format is:
  #  base32(type_1) + base32(type_2) + \
  #    base32_n(msb[0..53] * 2 + parity(msb[0..53])) + \
  #    base32_n(msb[64..127] * 2 + parity(msb[64..127))

  # we have 64 random bits in the format, so 2^64 - 1
  MAX_ENTROPY = 18446744073709551615

  # timestamp is 48 bits, so 2^48 - 1
  MAX_TIMESTAMP = 281474976710655

  # types
  TYPE_VM = "vm"
  TYPE_VM_STORAGE_VOLUME = "v1"
  TYPE_VM_HOST = "vh"
  TYPE_STORAGE_KEY_ENCRYPTION_KEY = "ke"
  TYPE_PROJECT = "pj"
  TYPE_ACCESS_TAG = "tg"
  # TYPE_ACCESS_POLICY = "pc"
  TYPE_ACCOUNT = "ac"
  TYPE_IPSEC_TUNNEL = "tn"
  TYPE_PRIVATE_SUBNET = "ps"
  TYPE_ADDRESS = "ad"
  TYPE_ASSIGNED_VM_ADDRESS = "av"
  TYPE_ASSIGNED_HOST_ADDRESS = "ah"
  TYPE_STRAND = "st"
  TYPE_SEMAPHORE = "sm"
  TYPE_SSHABLE = "sh"
  TYPE_PAGE = "pa"
  TYPE_NIC = "nc"
  TYPE_BILLING_RECORD = "br"
  TYPE_INVOICE = "1v"
  TYPE_BILLING_INFO = "b1"
  TYPE_PAYMENT_METHOD = "pm"
  TYPE_GITHUB_INSTALLATION = "g1"
  TYPE_GITHUB_RUNNER = "gr"
  TYPE_VM_POOL = "vp"
  TYPE_POSTGRES_RESOURCE = "pg"
  TYPE_POSTGRES_SERVER = "pv"
  TYPE_POSTGRES_TIMELINE = "pt"
  TYPE_MINIO_CLUSTER = "mc"
  TYPE_MINIO_POOL = "mp"
  TYPE_MINIO_SERVER = "ms"
  TYPE_DNS_ZONE = "dz"
  TYPE_DNS_RECORD = "dr"
  TYPE_DNS_SERVER = "ds"
  TYPE_FIREWALL_RULE = "fr"
  TYPE_FIREWALL = "fw"
  TYPE_POSTGRES_FIREWALL_RULE = "pf"
  TYPE_GITHUB_REPOSITORY = "gp"
  TYPE_LOAD_BALANCER = "1b"
  TYPE_CERT = "ce"
  TYPE_INFERENCE_ENDPOINT = "1e"
  TYPE_INFERENCE_ENDPOINT_REPLICA = "1r"
  TYPE_ACTION_TYPE = "tt"
  TYPE_ACCESS_CONTROL_ENTRY = "te"
  TYPE_SUBJECT_TAG = "ts"
  TYPE_ACTION_TAG = "ta"
  TYPE_OBJECT_TAG = "t0"
  TYPE_OBJECT_METATAG = "t2"
  TYPE_VM_HOST_SLICE = "vs"
  TYPE_KUBERNETES_CLUSTER = "kc"

  # Common entropy-based type for everything else
  TYPE_ETC = "et"

  CURRENT_TIMESTAMP_TYPES = [TYPE_STRAND, TYPE_SEMAPHORE]

  def self.generate(type)
    case type
    when *CURRENT_TIMESTAMP_TYPES
      generate_from_current_ts(type)
    else
      generate_random(type)
    end
  end

  def self.generate_random(type)
    timestamp = SecureRandom.random_number(MAX_TIMESTAMP)
    random_value = SecureRandom.random_number(MAX_ENTROPY)
    from_parts(timestamp, type, random_value & 0b11, random_value >> 2)
  end

  def self.generate_from_current_ts(type)
    random_value = SecureRandom.random_number(MAX_ENTROPY)
    from_parts(current_milliseconds, type, random_value & 0b11, random_value >> 2)
  end

  # InferenceApiKey does not have a type, and using et (TYPE_ETC) seems like a bad idea
  ACTION_TYPE_PREFIX_MAP = <<~TYPES.split("\n").map! { _1.split(": ") }.to_h.freeze
    Project: pj
    Vm: vm
    PrivateSubnet: ps
    Firewall: fw
    LoadBalancer: 1b
    InferenceEndpoint: 1e
    InferenceApiKey: 1t
    Postgres: pg
    SubjectTag: ts
    ActionTag: ta
    ObjectTag: t0
  TYPES
  def self.generate_vanity_action_type(action)
    prefix, suffix = action.split(":")
    prefix = ACTION_TYPE_PREFIX_MAP.fetch(prefix)
    generate_vanity("tt", prefix, suffix[0...7].tr("u", "v"))
  end

  def self.generate_vanity_action_tag(name)
    prefix, suffix = name.split(":")
    if suffix
      prefix = ACTION_TYPE_PREFIX_MAP.fetch(prefix)
    else
      prefix = nil
      suffix = name
    end
    generate_vanity("ta", prefix, suffix[0...7].tr("u", "v"))
  end

  def self.generate_vanity(type, prefix, suffix)
    raise "prefix over length 2" if prefix && prefix.length != 2
    raise "suffix over length 7" unless suffix.length <= 7
    full = "#{"0" if prefix}#{prefix}0#{suffix}".rjust(11, "z")
    from_parts(UBID.to_base32_n("zzzzzzzz") * 256, type, 0, UBID.to_base32_n(full) * 16)
  end

  def self.camelize(s)
    s.delete_prefix("TYPE").split("_").map(&:capitalize).join
  end

  # Map of prefixes to class name symbols, to avoid autoloading
  # classes until they are referenced by class_for_ubid
  TYPE2CLASSNAME = constants.select { _1.start_with?("TYPE_") }.reject { _1.to_s == "TYPE_ETC" }
    .map { [const_get(_1), camelize(_1.to_s).to_sym] }.to_h.freeze
  private_constant :TYPE2CLASSNAME

  def self.class_for_ubid(str)
    # :nocov:
    # Overridden in production and when forcing autoloads in tests
    if (sym = TYPE2CLASSNAME[str[..1]])
      Object.const_get(sym)
    end
    # :nocov:
  end

  def self.resolve_map(uuids)
    uuids.keys.group_by do
      ubid = from_uuidish(_1).to_s
      # Bad hack, needed because ApiKey does not use a fixed ubid type
      ubid.start_with?("et") ? ApiKey : class_for_ubid(ubid)
    end.each do |model, model_uuids|
      next unless model
      model.where(id: model_uuids).each do
        uuids[_1.id] = _1
      end
    end
    uuids
  end

  def self.decode(ubid)
    ubid_str = ubid.to_s
    uuid = UBID.parse(ubid_str).to_uuid
    klass = class_for_ubid(ubid)
    fail "Couldn't decode ubid: #{ubid_str}" if klass.nil?

    klass[uuid]
  end

  def self.from_uuidish(uuidish)
    value = Integer(uuidish.to_s.tr("-", ""), 16)
    new(value)
  end

  def self.to_uuid(ubid_str)
    parse(ubid_str).to_uuid
  rescue UBIDParseError
  end

  def self.uuid_class_match?(uuid, klass)
    uuid_type_match?(uuid, klass.ubid_type)
  end

  def self.uuid_type_match?(uuid, type)
    from_uuidish(uuid).type_match?(type)
  end

  def self.class_match?(ubid, klass)
    type_match?(ubid, klass.ubid_type)
  end

  def self.type_match?(ubid, type)
    ubid[..1] == type
  end

  def class_match?(klass)
    type_match?(klass.ubid_type)
  end

  def type_match?(type)
    to_s[..1] == type
  end

  def to_uuid
    # 8-4-4-4-12 format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    a = UBID.extract_bits_as_hex(@value, 24, 8)
    b = UBID.extract_bits_as_hex(@value, 20, 4)
    c = UBID.extract_bits_as_hex(@value, 16, 4)
    d = UBID.extract_bits_as_hex(@value, 12, 4)
    e = UBID.extract_bits_as_hex(@value, 0, 12)
    "#{a}-#{b}-#{c}-#{d}-#{e}"
  end

  def self.parse(s)
    fail UBIDParseError.new("Invalid encoding length: #{s.length}") unless s.length == 26

    type = s[0..1]

    top_bits_with_parity = to_base32_n(s[2..12])
    fail UBIDParseError.new("Invalid top bits parity") unless parity(top_bits_with_parity) == 0
    top_bits = (top_bits_with_parity >> 1)
    unix_ts_ms = get_bits(top_bits, 6, 53)
    version = get_bits(top_bits, 2, 5)
    rand_a = get_bits(top_bits, 0, 1)

    bottom_bits_with_parity = to_base32_n(s[13..])
    fail UBIDParseError.new("Invalid bottom bits parity") unless parity(bottom_bits_with_parity) == 0
    bottom_bits = (bottom_bits_with_parity >> 1)
    variant = get_bits(bottom_bits, 62, 63)
    rand_b = get_bits(bottom_bits, 0, 61)

    from_parts(unix_ts_ms, type, rand_a, rand_b, version: version, variant: variant)
  end

  def self.from_parts(unix_ts_ms, type, rand_a, rand_b, version: 0b1000, variant: 0b10)
    value = 0
    # timestamp (48 bits)
    value |= (unix_ts_ms & 0xffffffffffff) << 80
    # version (4 bits)
    value = set_bits(value, 76, 79, version)
    # rand_a (2 bits)
    value = set_bits(value, 74, 75, rand_a & 0b11)
    # type char 1 (5 bits)
    value = set_bits(value, 69, 73, to_base32(type[0]))
    # type char 2 (5 bits)
    value = set_bits(value, 64, 68, to_base32(type[1]))
    # variant (2 bits)
    value = set_bits(value, 62, 63, variant)
    # rand_b (62 bits)
    value |= (rand_b & 0x3fffffffffffffff)

    new(value)
  end

  def initialize(value)
    @value = value
  end

  def to_s
    result = ""
    # type
    result += UBID.from_base32(UBID.get_bits(@value, 69, 73))
    result += UBID.from_base32(UBID.get_bits(@value, 64, 68))
    # top-bits: 127..74 (54 bits)
    top_bits = UBID.get_bits(@value, 74, 127)
    result += UBID.from_base32_n((top_bits << 1) | UBID.parity(top_bits), 11)
    # bottom-bits: 63..0 (64 bits)
    bottom_bits = UBID.get_bits(@value, 0, 63)
    result += UBID.from_base32_n((bottom_bits << 1) | UBID.parity(bottom_bits), 13)
    result
  end

  def to_i
    @value
  end

  def inspect
    "#<UBID:#{TYPE2CLASSNAME[to_s[..1]] || "Unknown"} @ubid=#{to_s.inspect} @uuid=#{to_uuid.inspect}>"
  end

  #
  # Utility functions
  #

  def self.current_milliseconds
    (Time.now.to_r * 1000).to_i
  end

  def self.set_bits(n, from, to, bits)
    (from..to).each { |i|
      if (bits & (1 << (i - from))) != 0
        n |= (1 << i)
      end
    }
    n
  end

  def self.get_bits(n, from, to)
    result = 0
    (from..to).each { |i|
      if (n & (1 << i)) != 0
        result |= (1 << (i - from))
      end
    }
    result
  end

  BASE32_DATA = [
    "0O",
    "1IL",
    "2", "3", "4", "5", "6", "7", "8", "9",
    "A", "B", "C", "D", "E", "F", "G", "H",
    "J", "K", "M", "N", "P", "Q", "R", "S",
    "T", "V", "W", "X", "Y", "Z"
  ]

  def self.to_base32(c)
    c = c.upcase
    BASE32_DATA.each_with_index do |e, idx|
      if e.include? c
        return idx
      end
    end

    raise "Invalid base32 encoding: #{c}"
  end

  def self.to_base32_n(s)
    result = 0
    s.chars.each {
      result = result * 32 + to_base32(_1)
    }
    result
  end

  def self.from_base32(num)
    fail "Invalid base32 number: #{num}" if num < 0 || num >= 32
    BASE32_DATA[num][0].downcase
  end

  def self.from_base32_n(num, cnt)
    (cnt - 1).downto(0).map { |i|
      from_base32(get_bits(num, 5 * i, 5 * i + 4))
    }.join
  end

  def self.parity(num)
    if num == 0
      0
    elsif (num & 1) == 0
      parity(num >> 1)
    else
      1 - parity(num >> 1)
    end
  end

  def self.extract_bits_as_hex(value, from_digit, digit_count)
    bit_count = digit_count * 4
    from_bit = from_digit * 4
    bitmask = (1 << bit_count) - 1
    bits_i = (value & (bitmask << from_bit)) >> from_bit
    bits_i.to_s(16).rjust(digit_count, "0")
  end
end
