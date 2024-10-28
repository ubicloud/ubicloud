# frozen_string_literal: true

require_relative "../model"

RSpec.describe ResourceMethods do
  let(:sa) { Sshable.create_with_id(host: "test.localhost", raw_private_key_1: SshKey.generate.keypair) }

  it "discourages deleting models with delete method" do
    expect { sa.delete }.to raise_error(RuntimeError, /Calling delete is discouraged/)
  end

  it "allows deleting models with delete method if forced" do
    expect { sa.delete(force: true) }.not_to raise_error
  end

  it "allows deleting models with destroy" do
    expect { sa.destroy }.not_to raise_error
  end

  it "archives scrubbed version of the model when deleted" do
    skip_if_frozen_models
    scrubbed_values_hash = sa.values.merge(model_name: "Sshable")
    scrubbed_values_hash.delete(:raw_private_key_1)
    scrubbed_values_hash.delete(:raw_private_key_2)
    expect(DeletedRecord).to receive(:create).with(hash_including(model_values: scrubbed_values_hash))
    sa.destroy
  end
end
