---
name: ubicloud-onebox
description: Operate the local Ubicloud onebox (development environment). Use when the user wants to create, inspect, or manage Ubicloud resources like PostgreSQL servers, VMs, or other infrastructure locally.
user-invocable: true
---

# Ubicloud Onebox Skill

You are operating a local Ubicloud development onebox. Always run commands from the current project root.

**Prefer the API approach** for creating, inspecting, deleting resources and querying billing. Fall back to Ruby code execution only when the API doesn't support the operation (e.g., direct DB queries, HA changes, or internal state inspection). See [ruby-approach.md](ruby-approach.md) for Ruby patterns.

## API wrapper

Use `.devcontainer/scripts/invoke_ubicloud_api_curl.sh` for all API calls — it handles token acquisition automatically and is allowlisted so no approval prompts are needed.

```
invoke_ubicloud_api_curl.sh <METHOD> <path> [extra curl args...]
```

If it errors with a token/decryption failure (e.g. `Unable to decrypt encrypted column`), run `.devcontainer/scripts/rotate-pat-token.sh` to regenerate the PAT without touching the project setup. Only fall back to `register-pg-project.sh` if the account or project itself is missing.

## Common API patterns

### List projects

```bash
.devcontainer/scripts/invoke_ubicloud_api_curl.sh GET /project
```

### Create a PostgreSQL server

```bash
.devcontainer/scripts/invoke_ubicloud_api_curl.sh POST \
  /project/default/location/aws-us-west-2/postgres/<name> \
  -d '{"size": "m8gd.large", "storage_size": 118}'
```

Optional fields: `ha_type` ("none"/"async"/"sync"), `version`, `flavor`, `tags` (array of `{key, value}` objects).

After creation, wait until state is `running` using the polling helper:

```bash
.devcontainer/scripts/wait_for_postgres_state.sh <name> running [timeout_seconds]
```

The script polls every 15 seconds (default timeout: 600s) and exits 0 when the target state is reached, or 1 on timeout. Use `deleted` as the target state to wait for deletion (detects HTTP 404).

### Get PostgreSQL server details

```bash
.devcontainer/scripts/invoke_ubicloud_api_curl.sh GET \
  /project/default/location/aws-us-west-2/postgres/<name>
```

### List all PostgreSQL servers

```bash
.devcontainer/scripts/invoke_ubicloud_api_curl.sh GET \
  /project/default/location/aws-us-west-2/postgres
```

### Modify a PostgreSQL server (HA, size, etc.)

```bash
.devcontainer/scripts/invoke_ubicloud_api_curl.sh PATCH \
  /project/default/location/aws-us-west-2/postgres/<name> \
  -d '{"ha_type": "sync"}'
```

### Delete a PostgreSQL server

```bash
.devcontainer/scripts/invoke_ubicloud_api_curl.sh DELETE \
  /project/default/location/aws-us-west-2/postgres/<name>
```

Returns 204 on success. Wait for deletion to complete:

```bash
.devcontainer/scripts/wait_for_postgres_state.sh <name> deleted
```

### Get billing resources

```bash
.devcontainer/scripts/invoke_ubicloud_api_curl.sh GET \
  "/project/default/clickgres-billing/postgres-resources?start_time=<ISO8601>&end_time=<ISO8601>"
```

Optional filters:
- `&chc_org_id=<string>` — filter by `chc_org_id` tag value

Returns a deduplicated list of resources with billing activity in the time range:
```json
{"items": [{"project_id": "...", "resource_id": "...", "resource_name": "...", "resource_tags": {...}}]}
```

## Behavior guidelines

- Always prefer AWS instance type sizes (e.g. `m8gd.large`, `m8gd.xlarge`). The default size is `m8gd.large`. Non-AWS sizes like `standard-2` should not be used.
- Use the `default` project and `us-west-2` location unless the user specifies otherwise.
- Use `default` as the project ID in all paths — the script resolves it automatically. Never call `GET /project` just to get the ID.
- Use `wait_for_postgres_state.sh <name> <state>` to wait for resources to reach a target state (e.g. `running`, `deleted`). Never write manual polling loops.
- If a resource with the requested name already exists, report its current state instead of creating a duplicate.
- Pass the user's `$ARGUMENTS` (e.g. name, size) into the commands — do not hard-code names unless the user didn't provide one.
- For operations not available via API (direct DB access, HA toggling via semaphores, internal state), see [ruby-approach.md](ruby-approach.md).
