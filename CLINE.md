# CLINE Documentation

## Development cycle

1. Start services in the background (ignore if already running):

    ```sh
    # postgres
    postgres -D $PGDATA

    # victoria-metrics
    victoria-metrics -storageDataPath var/victoria-metrics-data

    # Web UI
    bundle exec rackup

    # API
    bundle exec puma -C config/puma.rb
    ```

2. Make code modifications
3. Run tests with `rake`
