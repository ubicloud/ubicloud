# Devcontainer Setup

## Usage

1. Open folder in devcontainer in VSCode or Cursor

1. Run prepare script
    ```bash
        .devcontainer/scripts/prepare-pg-ubicloud.sh
    ```

    The script will login against GitHub and AWS.    

1. Follow foreman logs

    Foreman is started automatically by the prepare script.
    To follow the logs:

    ```bash
        tail -f /var/log/foreman/foreman.log
    ```

### Claude Code

Claude code can be run inside devcontainer

```bash
    claude
```

use skill /ubicloud-onebox to interact with onebox

### Or use Pry

```bash
    bundle exec bin/pry
```

### Environment overrides

`.devcontainer/env-overrides.rb` is loaded by the container entrypoint and can be used to override configuration values. Changes to this file take effect on container restart — no rebuild required.

### Restart foreman if needed

```bash
    .devcontainer/scripts/start-foreman.sh --restart
```

### Connect to PG instance

```bash
    .devcontainer/scripts/ssh-pg.sh <server-name> <instance-index>
```

## Running Multiple Devcontainers Simultaneously (Test Mode)

1. Install devcontainer cli 
    ```bash
        brew install devcontainer
    ``` 

1. Each devcontainer instance needs a unique host port. By default port `3100` is used. To run a second instance on a different port.

   Start the container manually with a unique port and project name before opening VS Code:
    ```bash
    HOST_PORT=3101 COMPOSE_PROJECT_NAME=clickgres2 devcontainer up --workspace-folder .
    ```
    `COMPOSE_PROJECT_NAME` scopes all named volumes to the project, so each instance gets fully isolated data (`clickgres2_postgres-data`, etc.).

1. Open the VS Code and select "Attach to Running Container"

1. Navigate to the specific code folder under /workspaces/

1. To stop a specific instance:
    ```bash
    HOST_PORT=3101 COMPOSE_PROJECT_NAME=clickgres2 docker compose -f .devcontainer/docker-compose.yml down
    ```

## Teardown

### Stop containers

```bash
docker compose -f .devcontainer/docker-compose.yml down
```

### Full reset (remove volumes)

> **WARNING:** Delete all PostgresResource objects before running this, or AWS resources will leak. Use the `/ubicloud-onebox` Claude skill to delete them and confirm none remain.

```bash
docker compose -f .devcontainer/docker-compose.yml down -v
```


