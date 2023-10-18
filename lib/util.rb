# frozen_string_literal: true

require "net/ssh"
require "openssl"

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
end
