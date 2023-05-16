# frozen_string_literal: true

require "net/ssh"

RSpec.describe SshKey do
  it "can generate an ed25519 key that loads successfully" do
    # Catenate a few simple tests together for speedup.
    sk = described_class.generate

    # Test round trip.
    sk2 = described_class.from_binary(sk.keypair)
    expect(sk.keypair).to eq sk2.keypair

    expect {
      # Test parsing.
      Net::SSH::KeyFactory.load_data_private_key(sk.private_key)

      # Test caching.
      sk.private_key
      sk.public_key
      sk.public_key
    }.not_to raise_error
  end

  context "when render common public keys types often returned by ssh-agent" do
    it "can format ssh-rsa keys" do
      pair = OpenSSL::PKey::RSA.new <<TEST_KEY
-----BEGIN RSA PRIVATE KEY-----
MIIBOwIBAAJBAOkzqanQJFdaWVboinOjveOBvfG0tRm6g/aXEJD2qq0+DB5UtV48
S/m6fLxJn8P3Onz5EzIz+1+a3VyCXOv+ZQMCAwEAAQJBAKEK5l24uYABirSzvfkB
2L5l+JAUZQQxg7QkunIBhfhAEWm5sTdAZbkoUegjsDIPwTYA/GkfC40b5Szpd7WF
qTECIQD7/DZLGuaQDItlez6aDz7aup86dPXTuOFgTSEzMpCgVQIhAOzq1m/eb+sA
h17uHD/90xaFTitbWu5fg0xL/ZJlq+f3AiAWi/KvtbB7oyO16NkpH8QX/irRKDX2
w8wmucAGvLeEIQIgUnkVmO/YCfivJy7Ais4zU12obpNovh5luIOji/j0tNUCIQC1
zwE4g32X+TfVTofQt95jI5q6qBefY1ig6AfH7rhlVg==
-----END RSA PRIVATE KEY-----
TEST_KEY

      expect(described_class.public_key(pair)).to eq(
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAAQQDpM6mp0CRXWllW6Ipzo73jgb3xtLUZuoP2lxCQ9qqtPgweVLVePEv5uny8SZ/D9zp8+RMyM/tfmt1cglzr/mUD"
      )
    end

    it "can format an ed25519 VerifyKey" do
      # Test literals from net-ssh test_ed25519.rb.
      pub_in = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDB2NBh4GJPPUN1kXPMu8b633Xcv55WoKC3OkBjFAbzJ"
      pub_buf = Net::SSH::Buffer.new(Base64.decode64(pub_in.split(" ")[1]))
      expect(pub_buf.read_string).to eq("ssh-ed25519")
      pub = Net::SSH::Authentication::ED25519::PubKey.new(pub_buf.read_string)
      expect(described_class.public_key(pub)).to eq(pub_in)
    end

    it "errors on other kinds of objects" do
      expect {
        described_class.public_key(Class.new)
      }.to raise_error RuntimeError, "BUG: unrecognized key type"
    end
  end
end
