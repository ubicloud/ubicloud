# GitHub Runner Simulation

Simulation mode runs the control plane against simulated VM hosts, to
exercise the VM allocator with many GitHub runner requests. Hosts and VMs
exist only as database records: the allocator places VMs as usual, but no
command ever runs on a host, and a VM is provisioned as soon as it is
allocated. A simulator stands in for GitHub on both sides.

## Setup

```sh
export SIMULATION_MODE=true
export GITHUB_SIMULATOR_URL=http://<simulator-ip>:<port>
export GITHUB_RUNNER_SERVICE_PROJECT_ID=<any project uuid>
export ENABLE_GITHUB_WORKFLOW_POLLER=false

bin/simulation-seed --hosts 20                    # standard x64 hosts
bin/simulation-seed --hosts 5 --family premium    # premium hosts
```

Then run `web` and `respirate`, but not `monitor`, which would try to reach
the hosts. Runner labels are the ones in `config/github_runner_labels.yml`.

## Simulator → control plane

`POST /webhook/github` with a `workflow_job` payload, as GitHub sends it.
No signature is needed. Unknown installation ids are registered on first
sight.

```sh
curl -XPOST $CONTROL_PLANE/webhook/github \
  -H 'x-github-event: workflow_job' -H 'content-type: application/json' \
  -d '{"action": "queued",
       "installation": {"id": 1},
       "repository": {"full_name": "org/repo", "default_branch": "main"},
       "workflow_job": {"id": 1, "labels": ["ubicloud-standard-2"], "runner_id": null}}'
```

- `queued` creates a runner, which then gets a VM from the allocator.
- `in_progress` assigns the job to the runner. `workflow_job.runner_id` must
  be the id the simulator returned at registration, and `created_at` and
  `started_at` must be set.
- `completed` destroys the runner and its VM, freeing the host capacity.

A runner without a job is destroyed `SIMULATED_RUNNER_IDLE_SECONDS` (30 by
default) after registration.

## Control plane → simulator

The only GitHub API call the simulator must answer is the runner
registration, sent once the runner's VM is allocated:

```
POST $GITHUB_SIMULATOR_URL/repos/{owner}/{repo}/actions/runners/generate-jitconfig
Authorization: token simulated-{installation_id}

{"name": "<runner ubid>", "labels": ["ubicloud-standard-2"], "runner_group_id": 1, "work_folder": "/home/runner/work"}
```

It must respond with a 2xx and:

```json
{"runner": {"id": 1000}, "encoded_jit_config": "anything"}
```
