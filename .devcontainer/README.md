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


