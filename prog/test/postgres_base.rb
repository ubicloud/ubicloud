# frozen_string_literal: true

class Prog::Test::PostgresBase < Prog::Test::Base
  def self.assemble(provider:, project_name:, local_e2e: false)
    postgres_test_project = if Config.local_e2e_postgres_test_project_id
      Project.with_pk!(Config.local_e2e_postgres_test_project_id)
    else
      Project.create(name: project_name)
    end

    Project[Config.postgres_service_project_id] ||
      Project.create_with_id(Config.postgres_service_project_id || Project.generate_uuid, name: "Postgres-Service-Project")

    Strand.create(
      prog: name.delete_prefix("Prog::"),
      label: "start",
      stack: [{"provider" => provider, "postgres_test_project_id" => postgres_test_project.id, "local_e2e" => local_e2e}],
    )
  end

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

  def before_run
    super

    if pause_set?
      nap(60 * 60)
    end
  end

  def start(**)
    location_id, target_vm_size, target_storage_size_gib = self.class.postgres_test_location_options(frame["provider"])

    st = Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: frame["postgres_test_project_id"],
      location_id:,
      target_vm_size:,
      target_storage_size_gib:,
      **,
    )

    frame = {"postgres_resource_id" => st.id, "private_subnet_id" => st.subject.private_subnet_id}
    yield st.subject, frame if block_given?
    update_stack(frame)
    hop_wait_postgres_resource
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

  def nap_if_private_subnet
    if PrivateSubnet[frame["private_subnet_id"]]
      Clog.emit("Waiting for private subnet to be destroyed")
      nap 5
    end
  end

  def finish
    postgres_test_project.destroy unless Config.local_e2e_postgres_test_project_id
    fail_test(frame["fail_message"]) if frame["fail_message"]
    pop "Postgres tests are finished!"
  end

  def failed
    nap 15
  end

  def destroy
    if frame["fail_message"] && frame["local_e2e"]
      Prog::PageNexus.assemble("Local E2E Failure: #{self.class.name}", ["LocalE2eFailure", strand.ubid], strand.ubid, severity: "info")
      nap 60 * 60 * 24 * 365
    end

    hop_destroy_postgres
  end
end
