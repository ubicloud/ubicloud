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
end
