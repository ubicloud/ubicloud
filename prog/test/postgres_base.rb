# frozen_string_literal: true

class Prog::Test::PostgresBase < Prog::Test::Base
  def self.postgres_test_location_options(provider)
    if provider == "aws"
      location = Location[provider: "aws", project_id: Config.local_e2e_postgres_test_project_id, name: "us-west-2"]
      location.location_credential_aws ||
        LocationCredentialAws.create_with_id(location, access_key: Config.e2e_aws_access_key, secret_key: Config.e2e_aws_secret_key)
      family = "m8gd"
      vcpus = 2
      [location.id, Option.aws_instance_type_name(family, vcpus), Option::AWS_STORAGE_SIZE_OPTIONS[family][vcpus].first.to_i]
    else
      [Location::HETZNER_FSN1_ID, "standard-2", 128]
    end
  end

  def postgres_test_project
    @postgres_test_project ||= Project[frame["postgres_test_project_id"]]
  end

  def postgres_resource
    @postgres_resource ||= PostgresResource[frame["postgres_resource_id"]]
  end

  def representative_server
    @representative_server ||= postgres_resource.representative_server
  end

  def test_queries_sql
    File.read("./prog/test/testdata/order_analytics_queries.sql").freeze
  end

  def read_queries_sql
    File.read("./prog/test/testdata/order_analytics_read_queries.sql").freeze
  end

  def finish_test(success_msg)
    postgres_test_project.destroy unless Config.local_e2e_postgres_test_project_id
    fail_test(frame["fail_message"]) if frame["fail_message"]
    pop success_msg
  end
end
