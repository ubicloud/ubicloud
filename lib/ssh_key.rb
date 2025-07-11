# frozen_string_literal: true

require "base64"
require "stringio"

require "ed25519"
require "net/ssh"

class SshKey
  def self.generate
    new Ed25519::SigningKey.generate
  end

  def self.from_binary(keypair)
    new Ed25519::SigningKey.from_keypair keypair
  end

  def initialize(signer)
    @signer = signer
  end

  def keypair
    @signer.keypair
  end

  def private_key
    return @private_key if @private_key

    # N.B. net-ssh only supports one private key in a key_data at one
    # time, in ed25519.rb in 7.1.0:
    #
    #    raise ArgumentError.new("Only 1 key is supported in ssh keys #{num_keys} was in private key") unless num_keys == 1
    #
    # Kudos
    # https://dnaeon.github.io/openssh-private-key-binary-format/ with
    # excerpts and replication of primary references below.
    #
    # https://cvsweb.openbsd.org/src/usr.bin/ssh/PROTOCOL.key?annotate=HEAD
    #
    # byte[]  AUTH_MAGIC
    # string  ciphername
    # string  kdfname
    # string  kdfoptions
    # uint32  number of keys N
    # string  publickey1
    # string  publickey2
    # ...
    # string  publickeyN
    # string  encrypted, padded list of private keys
    #
    # We don't use OpenSSH encryption, preferring column encryption or
    # some other application method, so he encipherment will be none:
    #
    # > For unencrypted keys the cipher "none" and the KDF "none" are
    # > used with empty passphrases. The options if the KDF "none" are
    # > the empty string.
    #
    # uint32  checkint
    # uint32  checkint
    # byte[]  privatekey1
    # string  comment1
    # byte[]  privatekey2
    # string  comment2
    # ...
    # string  privatekeyN
    # string  commentN
    # byte    1
    # byte    2
    # byte    3
    # ...
    # byte    padlen % 255
    #
    # > The list of privatekey/comment pairs is padded with the bytes
    # > 1, 2, 3, ... until the total length is a multiple of the
    # > cipher block size.
    #
    # If here is no cipher, the padding is eight:
    # https://github.com/openssh/openssh-portable/blob/eba523f0a130f1cce829e6aecdcefa841f526a1a/cipher.c#L86
    #
    # The byte array containing he private key has a per-key defined
    # level of protocol.
    checkint = rand(0..(2**32 - 1))
    verify_key_bytes = @signer.verify_key.to_bytes
    nested_private_key = Net::SSH::Buffer.from(
      :long, checkint,
      :long, checkint,
      # 'encrypted' private keys
      :string, "ssh-ed25519",
      :string, verify_key_bytes,
      :string, @signer.keypair
    )

    # Negative modulus is a handy trick to fill out pads like this.
    padding = (nested_private_key.length % -8).abs
    nested_private_key.write("12345678".slice(0, padding))
    # :nocov:
    fail "BUG: padding broken" unless nested_private_key.length % 8 == 0
    # :nocov:

    @private_key = StringIO.open { |s|
      s.puts "-----BEGIN OPENSSH PRIVATE KEY-----"
      s.write Base64.encode64(Net::SSH::Buffer.from(
        :raw, "openssh-key-v1\0", # AUTH_MAGIC
        :string, "none", # cipher
        :string, "none", # kdf
        :string, "", # kdfoptions
        :long, 1, # number of keys N
        :string, verify_key_bytes, # publickey1,
        :string, nested_private_key.content
      ).content)
      s.puts "-----END OPENSSH PRIVATE KEY-----"
      s.string
    }
  end

  def self.public_key(public_key)
    type, binary = case public_key
    when OpenSSL::PKey::RSA
      ["ssh-rsa", public_key.to_blob]
    else
      verify_key = case public_key
      when Ed25519::VerifyKey
        public_key
      when Net::SSH::Authentication::ED25519::PubKey
        public_key.verify_key
      else
        fail "BUG: unrecognized key type"
      end

      ["ssh-ed25519", Net::SSH::Buffer.from(
        :string, "ssh-ed25519",
        :string, verify_key.to_bytes
      ).content]
    end

    type + " " + Base64.strict_encode64(binary)
  end

  def public_key
    @public_key ||= self.class.public_key(@signer.verify_key)
  end
end
