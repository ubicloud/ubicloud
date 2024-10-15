# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe ResourceMethods do
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
end
