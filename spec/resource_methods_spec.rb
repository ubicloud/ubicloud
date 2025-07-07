# frozen_string_literal: true

require_relative "../model"

RSpec.describe ResourceMethods do
  let(:sa) { Sshable.create_with_id(host: "test.localhost", raw_private_key_1: SshKey.generate.keypair) }

  it "#inspect hides sensitive and long columns" do
    [GithubRunner, PostgresResource, Vm, VmHost, MinioCluster, MinioServer, Cert].each do |klass|
      inspect_output = klass.new.inspect
      klass.redacted_columns.each do |column_key|
        expect(inspect_output).not_to include column_key.to_s
      end
    end
  end

  it "#inspect includes ubid only if available" do
    [GithubRunner, PostgresResource, Vm, VmHost, MinioCluster, MinioServer, Cert].each do |klass|
      ubid = klass.generate_ubid
      obj = klass.new
      expect(obj.inspect).to start_with "#<#{klass} @values={"
      obj.id = ubid.to_uuid.to_s
      expect(obj.inspect).to start_with "#<#{klass}[\"#{ubid}\"] @values={"
    end
  end

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
    expect(ArchivedRecord).to receive(:create).with(hash_including(model_values: scrubbed_values_hash))
    sa.destroy
  end

  it "inspect should show foreign keys as ubids, and exclude subseconds and timezones from times" do
    project = Project.new
    expect(project.inspect).to eq "#<Project @values={}>"

    project.created_at = Time.new(2024, 11, 13, 9, 16, 56.123456, 3600)
    expect(project.inspect).to eq "#<Project @values={created_at: \"2024-11-13 09:16:56\"}>"

    project.id = UBID.parse("pjhahqe5e90j3j6kfjtwtxpsps").to_uuid
    expect(project.inspect).to eq "#<Project[\"pjhahqe5e90j3j6kfjtwtxpsps\"] @values={created_at: \"2024-11-13 09:16:56\"}>"

    subject_tag = SubjectTag.new(project_id: project.id, name: nil)
    expect(subject_tag.inspect).to eq "#<SubjectTag @values={project_id: \"pjhahqe5e90j3j6kfjtwtxpsps\", name: nil}>"

    subject_tag.name = "a"
    expect(subject_tag.inspect).to eq "#<SubjectTag @values={project_id: \"pjhahqe5e90j3j6kfjtwtxpsps\", name: \"a\"}>"
  end

  it "Model.[] allows lookup using both uuid and ubid" do
    expect(Sshable[sa.id]).to eq sa
    expect(Sshable[sa.ubid]).to eq sa
  end

  it "Model.[] handles invalid ubids by passing them to the database" do
    expect(Sshable["sh1lawjdkcj25gq7hhb8tj3v6p"]).to be_nil
    expect { Sshable["sh4oc37mce4p3nsdy34qa0n9j8"] }.to raise_error(Sequel::DatabaseError)
  end
end
