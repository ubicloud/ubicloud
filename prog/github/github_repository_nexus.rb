# frozen_string_literal: true

require_relative "../../lib/util"

class Prog::Github::GithubRepositoryNexus < Prog::Base
  subject_is :github_repository

  semaphore :destroy

  def self.assemble(installation, name)
    DB.transaction do
      repository = GithubRepository.new_with_id(installation_id: installation.id, name: name)
      repository.skip_auto_validations(:unique) do
        repository.insert_conflict(target: [:installation_id, :name], update: {last_job_at: Time.now}).save_changes
      end
      Strand.new(prog: "Github::GithubRepositoryNexus", label: "wait") { _1.id = repository.id }
        .insert_conflict(target: :id).save_changes
    end
  end

  def client
    @client ||= Github.installation_client(github_repository.installation.installation_id).tap { _1.auto_paginate = true }
  end

  def check_queued_jobs
    queued_runs = client.repository_workflow_runs(github_repository.name, {status: "queued"})[:workflow_runs]
    Clog.emit("polled queued runs") { {polled_queued_runs: {repository_name: github_repository.name, count: queued_runs.count}} }

    remaining_quota = client.rate_limit.remaining / client.rate_limit.limit.to_f
    if remaining_quota < 0.1
      Clog.emit("low remaining quota") { {low_remaining_quota: {repository_name: github_repository.name, limit: client.rate_limit.limit, remaining: client.rate_limit.remaining}} }
      return (client.rate_limit.resets_at - Time.now).to_i
    end

    queued_labels = Hash.new(0)
    queued_runs.each do |run|
      jobs = client.workflow_run_attempt_jobs(github_repository.name, run[:id], run[:run_attempt])[:jobs]

      jobs.each do |job|
        next if job[:status] != "queued"
        next unless (label = job[:labels].find { Github.runner_labels.key?(_1) })
        queued_labels[label] += 1
      end
    end

    queued_labels.each do |label, count|
      idle_runner_count = github_repository.runners_dataset.where(label: label, workflow_job: nil).count
      next if (required_runner_count = count - idle_runner_count) && required_runner_count <= 0

      Clog.emit("extra runner needed") { {needed_extra_runner: {repository_name: github_repository.name, label: label, count: required_runner_count}} }

      required_runner_count.times do
        Prog::Vm::GithubRunner.assemble(
          github_repository.installation,
          repository_name: github_repository.name,
          label: label
        )
      end
    end
    (remaining_quota < 0.5) ? 15 * 60 : 5 * 60
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
    polling_interval = 5 * 60
    should_destroy = (Time.now - github_repository.last_job_at > 6 * 60 * 60)

    begin
      polling_interval = check_queued_jobs
    rescue Octokit::NotFound
      Clog.emit("not found repository") { {not_found_repository: {repository_name: github_repository.name}} }
      should_destroy = true
    end

    if should_destroy && github_repository.runners.count == 0
      github_repository.incr_destroy
      nap 0
    end

    nap polling_interval
  end

  label def destroy
    decr_destroy

    github_repository.destroy

    pop "github repository destroyed"
  end
end
