# frozen_string_literal: true

require_relative "../../lib/util"

class Prog::Test::Postgres < Prog::Test::Base
  semaphore :destroy

  def self.assemble(vm_host_id, test_cases)
    if Project[Config.postgres_service_project_id].nil?
      postgres_service_project = Project.create(name: "Postgres-Service-Project") { _1.id = Config.postgres_service_project_id }
      postgres_service_project.associate_with_project(postgres_service_project)
    end

    postgres_test_project = Project.create_with_id(name: "Postgres-Test-Project")
    postgres_test_project.associate_with_project(postgres_test_project)

    Strand.create_with_id(
      prog: "Test::Postgres",
      label: "start",
      stack: [{
        "vm_host_id" => vm_host_id,
        "test_cases" => test_cases,
        "postgres_test_project_id" => postgres_test_project.id
      }]
    )

  end

  label def start
    hop_test_postgres_resources
  end

  label def test_postgres_resources
    frame["test_cases"].each do |test_case|
      bud Prog::Test::PostgresResource, {"postgres_test_project_id" => frame["postgres_test_project_id"], "test_case" => test_case, "vm_host_id" => frame["vm_host_id"]}
    end
    hop_wait_tests
  end

  label def wait_tests
    # Check if any test failed
    failed_tests = reap.filter { |strand| strand.label == "failed" }
    failed_messages = failed_tests.map { |strand| strand.exitval.fetch("msg") }.join(", ")

    if failed_tests.any?
      fail_test({"fail_message" => "#{failed_tests.count} test cases failed. Details: #{failed_messages}"})
    end

    if leaf?
      hop_finish
    else
      nap 10
    end
  end

  label def finish
    pop "Postgres tests are finished!"
  end

  label def failed
    nap 15
  end
end
