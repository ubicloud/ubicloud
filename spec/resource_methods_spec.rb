# frozen_string_literal: true

RSpec.describe ResourceMethods do
  let(:sa) { Sshable.create_with_id(host: "test.localhost", raw_private_key_1: SshKey.generate.keypair) }

  it "archives scrubbed version of the model when deleted" do
    scrubbed_values_hash = sa.values.merge(model_name: "Sshable")
    scrubbed_values_hash.delete(:raw_private_key_1)
    scrubbed_values_hash.delete(:raw_private_key_2)
    expect(DeletedRecord).to receive(:create).with(hash_including(model_values: scrubbed_values_hash))
    sa.destroy
  end
end
