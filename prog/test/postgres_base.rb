# frozen_string_literal: true

class Prog::Test::PostgresBase < Prog::Test::Base
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
