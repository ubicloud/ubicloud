# frozen_string_literal: true

RSpec.describe ResourceMethods do
  let(:sa) { Sshable.create_with_id(host: "test.localhost", raw_private_key_1: SshKey.generate.keypair) }

  it "archives the model when deleted" do
    values_hash = sa.values.merge(model_name: "Sshable")
    expect(DeletedRecord).to receive(:create).with(hash_including(model_values: values_hash))
    sa.destroy
  end
end
