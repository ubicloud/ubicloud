# frozen_string_literal: true

class Prog::Test::PostgresBase < Prog::Test::Base
  def self.assemble(provider:, project_name:, family: nil, aws_location_name: "us-west-2", local_e2e: false)
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
      stack: [{
        "provider" => provider,
        "family" => family,
        "aws_location_name" => aws_location_name,
        "postgres_test_project_id" => postgres_test_project.id,
        "local_e2e" => local_e2e,
      }],
    )
  end

  def self.postgres_test_location_options(provider, family: nil, aws_location_name: "us-west-2")
    case provider
    when "aws"
      location = Location[provider: "aws", project_id: Config.local_e2e_postgres_test_project_id, name: aws_location_name]
      location.location_credential_aws ||
        if Config.e2e_aws_assume_role
          LocationCredentialAws.create_with_id(location, assume_role: Config.e2e_aws_assume_role)
        else
          LocationCredentialAws.create_with_id(location, access_key: Config.e2e_aws_access_key, secret_key: Config.e2e_aws_secret_key)
        end
      family = "m8gd"
      vcpus = 2
      [location.id, Option.aws_instance_type_name(family, vcpus), Option::AWS_STORAGE_SIZE_OPTIONS[family][vcpus].first.to_i]
    when "gcp"
      location = Location[provider: "gcp", project_id: nil]
      Prog::Test::Base.ensure_gcp_e2e_credential(location)
      family ||= "c4a-standard"
      vcpus = Option::GCP_STORAGE_SIZE_OPTIONS[family].keys.first
      [location.id, "#{family}-#{vcpus}", Option::GCP_STORAGE_SIZE_OPTIONS[family][vcpus].first.to_i]
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
    location_id, target_vm_size, target_storage_size_gib = self.class.postgres_test_location_options(
      frame["provider"],
      family: frame["family"],
      aws_location_name: frame["aws_location_name"] || "us-west-2",
    )

    st = Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: frame["postgres_test_project_id"],
      location_id:,
      target_vm_size:,
      target_storage_size_gib:,
      **,
    )

    frame = {
      "postgres_resource_id" => st.id,
      "private_subnet_id" => st.subject.private_subnet_id,
      "location_id" => location_id,
    }
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
    if PrivateSubnet[project_id: frame["postgres_test_project_id"]]
      Clog.emit("Waiting for private subnet to be destroyed")
      nap 5
    end
  end

  def nap_if_gcp_vpc
    if GcpVpc[project_id: frame["postgres_test_project_id"]]
      Clog.emit("Waiting for GCP VPC to be destroyed")
      nap 5
    end
  end

  def verify_timelines_destroyed(timeline_ids)
    remaining = PostgresTimeline.where(id: timeline_ids).select_map(:id)
    return if remaining.empty?
    Semaphore.incr(remaining, "destroy")
    Clog.emit("Verifying timelines are retained after resource destroy (found #{remaining.count})")
    nap 5
  end

  def finish
    postgres_test_project.destroy unless Config.local_e2e_postgres_test_project_id
    if (fail_message = frame["fail_message"])
      if frame["local_e2e"]
        pop fail_message
      else
        fail_test(fail_message)
      end
    end
    pop "Postgres tests are finished!"
  end

  def failed
    nap 15
  end

  def destroy
    if frame["fail_message"] && frame["local_e2e"]
      unless destroy_set?
        Prog::PageNexus.assemble("Local E2E Failure: #{self.class.name}", ["LocalE2eFailure", strand.ubid], strand.ubid, severity: "info")
        nap 60 * 60 * 24 * 365
      end

      Page.from_tag_parts("LocalE2eFailure", strand.ubid)&.incr_resolve
    end

    hop_destroy_postgres
  end

  # Rule edits fan out differently per provider. On GCP, Firewall bumps
  # update_firewall_rules on the subnet; SubnetNexus#wait then forwards
  # to the GcpVpc, whose VpcNexus runs the shared policy sync. On
  # metal/AWS, the subnet fans the semaphore out to its VMs. Wait for
  # the target chain to drain end-to-end: on GCP both subnet and VPC
  # must be back in `wait` with no pending semaphore, since the subnet
  # holds the semaphore until SubnetNexus wakes and forwards it.
  def wait_firewall_rules_applied
    ps = postgres_resource.private_subnet
    if (vpc = ps.gcp_vpc)
      nap 5 if ps.update_firewall_rules_set? || ps.strand.label != "wait" ||
        vpc.update_firewall_rules_set? || vpc.strand.label != "wait"
    elsif ps.update_firewall_rules_set? || ps.vms.any?(&:update_firewall_rules_set?)
      nap 5
    end
  end
end
