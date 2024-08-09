# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe ResourceMethods do
  it "hides sensitive and long columns" do
    [GithubRunner, PostgresResource, Vm, VmHost, MinioCluster, MinioServer, Cert].each do |klass|
      inspect_output = klass.new.inspect
      klass.redacted_columns.each do |column_key|
        expect(inspect_output).not_to include column_key.to_s
      end
    end
  end
end
