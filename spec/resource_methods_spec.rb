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
    scrubbed_values_hash = sa.values.merge(model_name: "Sshable")
    scrubbed_values_hash.delete(:raw_private_key_1)
    scrubbed_values_hash.delete(:raw_private_key_2)
    expect(DeletedRecord).to receive(:create).with(hash_including(model_values: scrubbed_values_hash))
    sa.destroy
  end

  it "inspect should show foreign keys as ubids, and exclude subseconds and timezones from times" do
    access_tag = AccessTag.new(project_id: UBID.parse("pjhahqe5e90j3j6kfjtwtxpsps").to_uuid, created_at: Time.new(2024, 11, 13, 9, 16, 56.123456, 3600))
    expect(access_tag.inspect).to eq "#<AccessTag @values={:project_id=>\"pjhahqe5e90j3j6kfjtwtxpsps\", :created_at=>\"2024-11-13 09:16:56\"}>"

    access_tag.id = UBID.parse("tgx1y9wja1064pncxffe7aw4s4").to_uuid
    expect(access_tag.inspect).to eq "#<AccessTag[\"tgx1y9wja1064pncxffe7aw4s4\"] @values={:project_id=>\"pjhahqe5e90j3j6kfjtwtxpsps\", :created_at=>\"2024-11-13 09:16:56\"}>"
  end
end
