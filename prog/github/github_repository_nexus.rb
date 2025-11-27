# frozen_string_literal: true

require_relative "../../lib/util"

class Prog::Github::GithubRepositoryNexus < Prog::Base
  subject_is :github_repository

  def self.assemble(installation, name, default_branch)
    DB.transaction do
      repository = GithubRepository.new(installation_id: installation.id, name: name)
      repository.skip_auto_validations(:unique) do
        updates = {last_job_at: Time.now}
        updates[:default_branch] = default_branch if default_branch
        repository.insert_conflict(target: [:installation_id, :name], update: updates).save_changes
      end
      Strand.new(prog: "Github::GithubRepositoryNexus", label: "wait") { it.id = repository.id }
        .insert_conflict(target: :id).save_changes
    end
  end

  def client
    @client ||= Github.installation_client(github_repository.installation.installation_id).tap { it.auto_paginate = true }
  end

  # We dynamically adjust the polling interval based on the remaining rate
  # limit. It's 5 minutes by default, but it can be increased if the rate limit
  # is low.
  def polling_interval
    @polling_interval ||= 5 * 60
  end

  def check_queued_jobs
    unless github_repository.installation.project.active?
      @polling_interval = 24 * 60 * 60
      return
    end
    queued_runs = client.repository_workflow_runs(github_repository.name, {status: "queued"})[:workflow_runs]
    Clog.emit("polled queued runs") { {polled_queued_runs: {repository_name: github_repository.name, count: queued_runs.count}} }

    # We check the rate limit after the first API call to avoid unnecessary API
    # calls to fetch only the rate limit. Every response includes the rate limit
    # information in the headers.
    remaining_quota = client.rate_limit.remaining / client.rate_limit.limit.to_f
    if remaining_quota < 0.1
      Clog.emit("low remaining quota") { {low_remaining_quota: {repository_name: github_repository.name, limit: client.rate_limit.limit, remaining: client.rate_limit.remaining}} }
      @polling_interval = (client.rate_limit.resets_at - Time.now).to_i
      return
    end

    queued_labels = Hash.new(0)
    queued_runs.first(200).each do |run|
      jobs = client.workflow_run_attempt_jobs(github_repository.name, run[:id], run[:run_attempt])[:jobs]

      jobs.each do |job|
        next if job[:status] != "queued"
        if (label = job[:labels].find { Github.runner_labels.key?(it) })
          queued_labels[[label, label]] += 1 # Actual label is the same as the label for predefined labels
        elsif (custom_label = GithubCustomLabel.first(installation_id: github_repository.installation.id, name: job[:labels]))
          queued_labels[[custom_label.name, custom_label.alias_for]] += 1
        end
      end
    end

    queued_labels.each do |(actual_label, label), count|
      idle_runner_count = github_repository.runners_dataset.where(actual_label:, workflow_job: nil).count
      # The calculation of the required_runner_count isn't atomic because it
      # requires multiple API calls and database queries. However, it will
      # eventually settle on the correct value. If we create more runners than
      # necessary, the excess will be recycled after 5 minutes at no extra cost
      # to the customer. If fewer runners are created than needed, the system
      # will generate more in the next cycle.
      next if (required_runner_count = count - idle_runner_count) && required_runner_count <= 0

      Clog.emit("extra runner needed") { {needed_extra_runner: {repository_name: github_repository.name, label: label, actual_label: actual_label, count: required_runner_count}} }

      required_runner_count.times do
        Prog::Github::GithubRunnerNexus.assemble(
          github_repository.installation,
          repository_name: github_repository.name,
          label:,
          actual_label:
        )
      end
    end

    @polling_interval = (remaining_quota < 0.5) ? 15 * 60 : 5 * 60
  end

  def cleanup_cache
    # Destroy cache entries not accessed in last 7 days or
    # created more than 7 days ago and not accessed yet.
    seven_days_ago = Time.now - 7 * 24 * 60 * 60
    cond = Sequel.expr { (last_accessed_at < seven_days_ago) | ((last_accessed_at =~ nil) & (created_at < seven_days_ago)) }
    github_repository.cache_entries_dataset
      .where(cond)
      .limit(200)
      .destroy_where(cond)

    # Destroy cache entries if it is created 30 minutes ago
    # but couldn't committed yet. 30 minutes decided as during
    # our performance tests uploading 10GB of data (which is
    # the max size for a single cache entry) takes ~8 minutes at most.
    # To be on the safe side, ~2x buffer is added.
    cond = Sequel.expr(committed_at: nil)
    github_repository.cache_entries_dataset
      .where { created_at < Time.now - 30 * 60 }
      .where(cond)
      .limit(200)
      .destroy_where(cond)

    # Destroy oldest cache entries if the total usage exceeds the limit.
    dataset = github_repository.cache_entries_dataset.exclude(size: nil)
    total_usage = dataset.sum(:size).to_i
    storage_limit = github_repository.installation.cache_storage_gib * 1024 * 1024 * 1024
    if total_usage > storage_limit
      dataset.order(:created_at).limit(200).all do |oldest_entry|
        oldest_entry.destroy
        total_usage -= oldest_entry.size
        break if total_usage <= storage_limit
      end
    end

    if github_repository.cache_entries.empty?
      Clog.emit("Deleting empty bucket and tokens") { {deleting_empty_bucket: {repository_name: github_repository.name}} }
      github_repository.destroy_blob_storage
    end
  end

  def before_run
    when_destroy_set? do
      if strand.label != "destroy"
        register_deadline(nil, 5 * 60)
        hop_destroy
      end
    end
  end

  label def wait
    cleanup_cache if github_repository.access_key
    nap 15 * 60 if Time.now - github_repository.last_job_at > 6 * 60 * 60

    begin
      check_queued_jobs if Config.enable_github_workflow_poller
    rescue Octokit::NotFound
      Clog.emit("not found repository") { {not_found_repository: {repository_name: github_repository.name}} }
      if github_repository.runners.count == 0
        github_repository.incr_destroy
        nap 0
      end
    end

    # check_queued_jobs may have changed the default polling interval based on
    # the remaining rate limit.
    nap polling_interval
  end

  label def destroy
    decr_destroy

    unless github_repository.runners.empty?
      Clog.emit("Cannot destroy repository with active runners") { {not_destroyed_repository: {repository_name: github_repository.name}} }
      nap 5 * 60
    end

    github_repository.cache_entries_dataset.destroy
    github_repository.destroy_blob_storage if github_repository.access_key
    github_repository.destroy

    pop "github repository destroyed"
  end
end
