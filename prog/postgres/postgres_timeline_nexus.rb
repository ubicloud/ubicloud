# frozen_string_literal: true

require "forwardable"
require "aws-sdk-iam"

class Prog::Postgres::PostgresTimelineNexus < Prog::Base
  subject_is :postgres_timeline

  extend Forwardable

  def_delegators :postgres_timeline, :blob_storage_client

  def self.assemble(location_id:, parent_id: nil)
    if parent_id && PostgresTimeline[parent_id].nil?
      fail "No existing parent"
    end

    unless (location = Location[location_id])
      fail "No existing location"
    end

    DB.transaction do
      postgres_timeline = PostgresTimeline.create(
        parent_id: parent_id,
        access_key: SecureRandom.hex(16),
        secret_key: SecureRandom.hex(32),
        location_id: location.id
      )
      Strand.create_with_id(postgres_timeline, prog: "Postgres::PostgresTimelineNexus", label: "start")
    end
  end

  def before_run
    when_destroy_set? do
      if strand.label != "destroy"
        hop_destroy
      end
    end
  end

  label def start
    if postgres_timeline.blob_storage
      setup_blob_storage
      hop_setup_bucket
    end

    hop_wait_leader
  end

  label def setup_bucket
    nap 1 if postgres_timeline.aws? && !Config.aws_postgres_iam_access && !aws_access_key_is_available?

    # Create bucket for the timeline
    postgres_timeline.create_bucket
    postgres_timeline.set_lifecycle_policy
    hop_wait_leader
  end

  label def wait_leader
    nap 5 if postgres_timeline.leader.nil? || postgres_timeline.leader.strand.label != "wait"
    hop_wait
  end

  label def wait
    dependent = PostgresServer[timeline_id: postgres_timeline.id]
    backups = postgres_timeline.backups
    if dependent.nil? && backups.empty? && Time.now - postgres_timeline.created_at > 10 * 24 * 60 * 60
      Clog.emit("Self-destructing timeline as no leader or backups are present and it is older than 10 days") { postgres_timeline }
      hop_destroy
    end

    nap 20 * 60 if postgres_timeline.blob_storage.nil?

    # For the purpose of missing backup pages, we act like the very first backup
    # is taken at the creation, which ensures that we would get a page if and only
    # if no backup is taken for 2 days.
    latest_backup_completed_at = backups.map(&:last_modified).max || postgres_timeline.created_at
    if postgres_timeline.leader && latest_backup_completed_at < Time.now - 2 * 24 * 60 * 60 # 2 days
      Prog::PageNexus.assemble("Missing backup at #{postgres_timeline}!", ["MissingBackup", postgres_timeline.id], postgres_timeline.ubid)
    else
      Page.from_tag_parts("MissingBackup", postgres_timeline.id)&.incr_resolve
    end

    if postgres_timeline.need_backup?
      hop_take_backup
    end

    nap 20 * 60
  end

  label def take_backup
    # It is possible that we already started backup but crashed before saving
    # the state to database. Since backup taking is an expensive operation,
    # we check if backup is truly needed.
    if postgres_timeline.need_backup?
      postgres_timeline.leader.vm.sshable.cmd("common/bin/daemonizer 'sudo postgres/bin/take-backup #{postgres_timeline.leader.resource.version}' take_postgres_backup")
      postgres_timeline.latest_backup_started_at = Time.now
      postgres_timeline.save_changes
    end

    hop_wait
  end

  label def destroy
    decr_destroy
    destroy_blob_storage if postgres_timeline.blob_storage
    postgres_timeline.destroy
    pop "postgres timeline is deleted"
  end

  def destroy_blob_storage
    return destroy_aws_s3 if postgres_timeline.aws?

    admin_client.admin_remove_user(postgres_timeline.access_key)
    admin_client.admin_policy_remove(postgres_timeline.ubid)
  end

  def destroy_aws_s3
    if Config.aws_postgres_iam_access
      iam_client.delete_policy(policy_arn: postgres_timeline.aws_s3_policy_arn)
    else
      iam_client.list_attached_user_policies(user_name: postgres_timeline.ubid).attached_policies.each do
        iam_client.detach_user_policy(user_name: postgres_timeline.ubid, policy_arn: it.policy_arn)
        iam_client.delete_policy(policy_arn: it.policy_arn)
      end

      iam_client.list_access_keys(user_name: postgres_timeline.ubid).access_key_metadata.each do
        iam_client.delete_access_key(user_name: postgres_timeline.ubid, access_key_id: it.access_key_id)
      end
      iam_client.delete_user(user_name: postgres_timeline.ubid)
    end
  end

  def setup_blob_storage
    return setup_aws_s3 if postgres_timeline.aws?

    # Setup user keys and policy for the timeline
    admin_client.admin_add_user(postgres_timeline.access_key, postgres_timeline.secret_key)
    admin_client.admin_policy_add(postgres_timeline.ubid, postgres_timeline.blob_storage_policy)
    admin_client.admin_policy_set(postgres_timeline.ubid, postgres_timeline.access_key)
  end

  def setup_aws_s3
    policy = iam_client.create_policy(policy_name: postgres_timeline.aws_s3_policy_name, policy_document: postgres_timeline.blob_storage_policy.to_json)
    unless Config.aws_postgres_iam_access
      iam_client.create_user(user_name: postgres_timeline.ubid)
      iam_client.attach_user_policy(user_name: postgres_timeline.ubid, policy_arn: policy.policy.arn)
      response = iam_client.create_access_key(user_name: postgres_timeline.ubid)
      postgres_timeline.update(access_key: response.access_key.access_key_id, secret_key: response.access_key.secret_access_key)
      postgres_timeline.leader.incr_refresh_walg_credentials
    end # the policy is later attached at the postgres_server level
  end

  def aws_access_key_is_available?
    iam_client.list_access_keys(user_name: postgres_timeline.ubid).access_key_metadata.any? { it.access_key_id == postgres_timeline.access_key }
  end

  def iam_client
    postgres_timeline.location.location_credential.iam_client
  end

  def admin_client
    @admin_client ||= Minio::Client.new(
      endpoint: postgres_timeline.blob_storage_endpoint,
      access_key: postgres_timeline.blob_storage.admin_user,
      secret_key: postgres_timeline.blob_storage.admin_password,
      ssl_ca_data: postgres_timeline.blob_storage.root_certs
    )
  end
end
