# frozen_string_literal: true

require "net/ssh"
require "openssl"
require "erubi"
require "tilt"
require "fileutils"

module Util
  # A minimal, non-cached SSH implementation.
  #
  # It must log into an account that can escalate to root via "sudo,"
  # which typically includes the "root" account reflexively.  The
  # ssh-agent is employed by default here, since personnel are thought
  # to be involved with preparing new VmHosts.
  def self.rootish_ssh(host, user, keys, cmd)
    Net::SSH.start(host, user,
      Sshable::COMMON_SSH_ARGS.merge(key_data: keys,
        use_agent: Config.development?)) do |ssh|
      ret = ssh.exec!(cmd)
      fail "Ssh command failed: #{ret}" unless ret.exitstatus.zero?
      ret
    end
  end

  def self.parse_key(key_data)
    OpenSSL::PKey::EC.new(key_data)
  rescue OpenSSL::PKey::ECError, OpenSSL::PKey::DSAError
    OpenSSL::PKey::RSA.new(key_data)
  end

  def self.create_root_certificate(common_name:, duration:)
    create_certificate(
      subject: "/C=US/O=Ubicloud/CN=#{common_name}",
      extensions: ["basicConstraints=CA:TRUE", "keyUsage=cRLSign,keyCertSign", "subjectKeyIdentifier=hash"],
      duration: duration
    ).map(&:to_pem)
  end

  def self.create_certificate(subject:, duration:, extensions: [], issuer_cert: nil, issuer_key: nil)
    cert = OpenSSL::X509::Certificate.new
    key = OpenSSL::PKey::EC.generate("prime256v1")

    # If the issuer is nil, we will create a self-signed certificate.
    if issuer_cert.nil?
      issuer_cert = cert
      issuer_key = key
    end

    # Set certificate details
    cert.version = 2 # X.509v3
    cert.serial = OpenSSL::BN.rand(128, 0)
    cert.subject = OpenSSL::X509::Name.parse(subject)
    cert.issuer = issuer_cert.subject
    cert.not_before = Time.now
    cert.not_after = Time.now + duration
    cert.public_key = key

    # Add extensions
    ef = OpenSSL::X509::ExtensionFactory.new
    ef.subject_certificate = cert
    ef.issuer_certificate = issuer_cert
    extensions.each do |extension|
      cert.add_extension(ef.create_extension(extension))
    end

    # Sign
    cert.sign(issuer_key, OpenSSL::Digest.new("SHA256"))

    [cert, key]
  end

  def self.exception_to_hash(ex)
    {exception: {message: ex.message, class: ex.class.to_s, backtrace: ex.backtrace, cause: ex.cause.inspect}}
  end

  def self.safe_write_to_file(filename, content)
    FileUtils.mkdir_p(File.dirname(filename))
    temp_filename = filename + ".tmp"
    File.open("#{temp_filename}.lock", File::RDWR | File::CREAT) do |lock_file|
      lock_file.flock(File::LOCK_EX)
      File.write(temp_filename, content)
      File.rename(temp_filename, filename)
    end
  end

  def self.send_email(...)
    EmailRenderer.sendmail("/", ...)
  end

  def self.populate_ipv4_txt
    ips = Address.where { (family(cidr) =~ 4) & (routed_to_host_id !~ id) }
      .map { NetAddr::IPv4Net.new(it.cidr.network, NetAddr::Mask32.new(16)).to_s }
    ips.uniq!
    ips.sort!
    File.open("var/ips-v4.txt", "w") { it.write(ips.join("\n")) }
  end
end
