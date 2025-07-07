# PostgreSQL Fuzz Testing Framework for Ubicloud

A comprehensive testing framework for PostgreSQL databases on Ubicloud, designed to validate database operations, high availability, replication, scaling, maintenance operations, and data integrity.

## Features

- **Comprehensive Testing**: Tests database creation, connectivity, data operations, and cleanup
- **High Availability Validation**: Tests synchronous and asynchronous replication
- **Scaling Operations**: Tests database scaling up/down for compute and storage
- **HA Type Changes**: Tests changing between none, async, and sync HA types
- **Maintenance Operations**: Tests maintenance windows, restarts, and configuration updates
- **Security Testing**: Tests password resets and firewall rule management
- **Backup & Restore**: Tests database backup and restore functionality
- **Read Replica Testing**: Creates and validates read replicas with failover scenarios
- **Data Integrity Checks**: Validates data consistency using checksums and row counts
- **Performance Metrics**: Collects and analyzes database performance metrics
- **Stress Testing**: Simulates high-load conditions and concurrent operations
- **Chaos Engineering**: Simulates failures and validates recovery
- **Parallel Execution**: Supports running multiple test scenarios concurrently
- **Detailed Reporting**: Generates comprehensive JSON reports with test results

## Prerequisites

- Python 3.8 or higher
- Access to Ubicloud API with valid credentials
- PostgreSQL client libraries

## Installation

1. Install Python dependencies:
```bash
pip install -r requirements.txt
```

2. Ensure you have valid Ubicloud API credentials in a configuration file (see Configuration section).

## Configuration

Create a configuration file (e.g., `.local-api-credentials`) with your Ubicloud API credentials:

```
BASE_URL=http://api.localhost:3000
BEARER_AUTH_TOKEN=your-bearer-token-here
TEST_PROJECT=your-project-id
TEST_LOCATION=eu-central-h1
```

## Usage

### Basic Usage

Run the fuzz tester with a simple test scenario:

```bash
python postgres_fuzz_tester.py --config .local-api-credentials --scenarios sample_test.yaml
```

### Advanced Usage

Run with custom output file and verbose logging:

```bash
python postgres_fuzz_tester.py \
  --config .local-api-credentials \
  --scenarios test_scenarios.yaml \
  --output my_test_report.json \
  --verbose
```

Run scenarios in parallel:

```bash
python postgres_fuzz_tester.py \
  --config .local-api-credentials \
  --scenarios test_scenarios.yaml \
  --parallel 3
```

### Command Line Options

- `--config, -c`: Path to configuration file (required)
- `--scenarios, -s`: Path to test scenarios file (required)
- `--output, -o`: Output file for test report (optional)
- `--parallel, -p`: Number of parallel test scenarios (default: 1)
- `--verbose, -v`: Enable verbose logging (optional)

## Available Test Actions

The fuzz tester supports the following test actions:

### Database Lifecycle
- **create_database**: Create a new PostgreSQL database with specified configuration
- **validate_connection**: Test database connectivity and basic operations
- **cleanup**: Clean up created databases and resources

### Data Operations
- **write_data**: Insert test data into multiple tables with integrity validation
- **validate_replication**: Check replication status and data consistency

### Scaling Operations
- **scale_up**: Scale database compute size and/or storage capacity
- **scale_down**: Scale down database compute size (storage cannot be reduced)

### High Availability Management
- **change_ha_type**: Change between none, async, and sync HA types
- **create_read_replica**: Create and validate read replicas
- **test_failover**: Test failover scenarios with data integrity checks

### Maintenance & Configuration
- **set_maintenance_window**: Configure maintenance window timing
- **restart_database**: Restart database and validate recovery
- **update_config**: Update PostgreSQL and PgBouncer configuration parameters

### Security Operations
- **reset_password**: Reset superuser password and validate new credentials
- **test_firewall_rules**: Create and test firewall rules for database access

### Backup & Recovery
- **test_backup_restore**: Test database backup and restore with data integrity validation

### Performance Testing
- **collect_metrics**: Collect and analyze database performance metrics
- **stress_test**: Run stress tests with concurrent operations for specified duration

## Test Scenarios

Test scenarios are defined in YAML files. Each scenario contains a series of steps that test different aspects of PostgreSQL functionality.

### Sample Scenario - Basic Operations

```yaml
scenarios:
  - name: "basic_database_test"
    description: "Test basic database operations"
    steps:
      - action: "create_database"
        params:
          size: "standard-2"
          storage_size: 64
          ha_type: "none"
          version: "17"
          flavor: "standard"
      - action: "validate_connection"
      - action: "write_data"
        params:
          table_count: 3
          rows_per_table: 100
      - action: "collect_metrics"
      - action: "cleanup"
```

### Sample Scenario - Scaling Operations

```yaml
scenarios:
  - name: "database_scaling_test"
    description: "Test database scaling operations"
    steps:
      - action: "create_database"
        params:
          size: "standard-2"
          storage_size: 64
          ha_type: "none"
      - action: "validate_connection"
      - action: "scale_up"
        params:
          new_size: "standard-4"
          new_storage_size: 128
      - action: "validate_connection"
      - action: "scale_down"
        params:
          new_size: "standard-2"
      - action: "cleanup"
```

### Sample Scenario - HA Type Changes

```yaml
scenarios:
  - name: "ha_type_change_test"
    description: "Test changing HA types"
    steps:
      - action: "create_database"
        params:
          size: "standard-2"
          storage_size: 64
          ha_type: "none"
      - action: "validate_connection"
      - action: "change_ha_type"
        params:
          new_ha_type: "async"
      - action: "validate_replication"
      - action: "change_ha_type"
        params:
          new_ha_type: "sync"
      - action: "validate_replication"
      - action: "cleanup"
```

## Test Scenarios Included

### 1. Basic Database Operations
- Tests database creation, connection, and basic data operations
- Validates CRUD operations and data integrity

### 2. Database Scaling Test
- Tests scaling up compute and storage resources
- Tests scaling down compute resources
- Validates connectivity and operations after scaling

### 3. HA Type Change Test
- Tests changing from none → async → sync HA types
- Validates replication functionality after each change

### 4. Maintenance & Configuration Test
- Tests setting maintenance windows
- Tests configuration updates for PostgreSQL and PgBouncer
- Tests database restarts and recovery

### 5. Security & Firewall Test
- Tests password reset functionality
- Tests firewall rule creation and management
- Validates security configurations

### 6. Backup & Restore Test
- Tests database backup and restore operations
- Validates data integrity after restore
- Tests point-in-time recovery

### 7. Comprehensive HA Test
- Tests complete high availability setup
- Tests read replica creation and failover
- Validates data consistency across replicas

### 8. Performance Stress Test
- Tests database under high load conditions
- Runs concurrent operations for specified duration
- Collects performance metrics during stress

### 9. Complete Lifecycle Test
- Tests entire database lifecycle with all operations
- Combines scaling, HA changes, configuration updates
- Comprehensive validation of all features

### 10. Flavor Testing
- Tests different PostgreSQL flavors (standard, paradedb, lantern)
- Validates flavor-specific functionality and scaling

### 11. Version Compatibility Test
- Tests different PostgreSQL versions (16, 17)
- Validates version-specific features and operations

### 12. Edge Case Testing
- Tests error conditions and recovery scenarios
- Validates system behavior under unusual conditions

## Action Parameters

### create_database
- `size`: VM size (standard-2, standard-4, standard-8)
- `storage_size`: Storage size in GiB
- `ha_type`: High availability type (none, async, sync)
- `version`: PostgreSQL version (16, 17)
- `flavor`: Database flavor (standard, paradedb, lantern)

### write_data
- `table_count`: Number of tables to create
- `rows_per_table`: Number of rows to insert per table

### scale_up
- `new_size`: Target VM size
- `new_storage_size`: Target storage size in GiB

### scale_down
- `new_size`: Target VM size (storage cannot be reduced)

### change_ha_type
- `new_ha_type`: Target HA type (none, async, sync)

### set_maintenance_window
- `maintenance_hour`: Hour of day for maintenance (0-23)

### stress_test
- `duration_minutes`: Duration of stress test in minutes

## Validation Mechanisms

### Data Integrity
- **Checksums**: MD5 checksums of table data to detect corruption
- **Row Counts**: Verification of expected vs actual row counts
- **Cross-Replica Consistency**: Validates data consistency across replicas

### Replication Validation
- **LSN Monitoring**: Tracks Log Sequence Numbers for replication lag
- **Standby Status**: Monitors replication connection status
- **Data Consistency**: Ensures data appears correctly on all replicas
- **HA Type Verification**: Confirms HA configuration changes

### Scaling Validation
- **Resource Verification**: Confirms compute and storage changes
- **Performance Impact**: Measures performance before/after scaling
- **Data Preservation**: Ensures no data loss during scaling

### Configuration Validation
- **Parameter Verification**: Confirms configuration changes applied
- **Restart Recovery**: Validates database recovery after restarts
- **Maintenance Window**: Confirms maintenance window settings

### Security Validation
- **Password Changes**: Validates new password functionality
- **Firewall Rules**: Tests network access with new rules
- **Connection Security**: Ensures secure connections maintained

## Output and Reporting

The framework generates detailed JSON reports containing:

- **Test Summary**: Overall success/failure rates and timing
- **Scenario Results**: Individual scenario outcomes and performance
- **Step Details**: Granular information about each test step
- **Error Information**: Detailed error messages and stack traces
- **Performance Metrics**: Database and replication performance data
- **Scaling Results**: Before/after resource configurations
- **Security Test Results**: Password and firewall validation outcomes

### Sample Report Structure

```json
{
  "test_run_summary": {
    "timestamp": "2025-01-07T22:30:00",
    "total_scenarios": 15,
    "successful_scenarios": 14,
    "failed_scenarios": 1,
    "total_duration": 2456.78
  },
  "scenarios": [
    {
      "name": "database_scaling_test",
      "success": true,
      "duration": 345.67,
      "summary": {
        "total_steps": 7,
        "successful_steps": 7,
        "failed_steps": 0,
        "databases_created": 1
      },
      "steps": [
        {
          "name": "scale_up",
          "success": true,
          "duration": 120.45,
          "message": "Database scaled from standard-2/64GB to standard-4/128GB"
        }
      ]
    }
  ]
}
```

## Database Cleanup

The framework automatically cleans up created databases after each scenario. However, if tests are interrupted, you may need to manually clean up resources through the Ubicloud console.

## Troubleshooting

### Common Issues

1. **Connection Timeouts**: Increase timeout values in the configuration
2. **API Rate Limits**: Add delays between API calls or reduce parallelism
3. **Database Creation Failures**: Check quotas and resource availability
4. **SSL Certificate Issues**: Verify SSL configuration for database connections
5. **Scaling Timeouts**: Allow more time for scaling operations (up to 15 minutes)
6. **HA Type Change Failures**: Ensure sufficient resources for HA configurations

### Debug Mode

Enable verbose logging to get detailed information about test execution:

```bash
python postgres_fuzz_tester.py --config .local-api-credentials --scenarios test_scenarios.yaml --verbose
```

## Performance Considerations

- **Scaling Operations**: Can take 5-15 minutes depending on size changes
- **HA Type Changes**: May take 10-20 minutes for sync/async configurations
- **Backup/Restore**: Duration depends on database size and data volume
- **Stress Tests**: Configurable duration, recommended 2-10 minutes for testing

## Extending the Framework

### Adding New Test Actions

1. Implement the test method in the `PostgresFuzzTester` class
2. Add the action handler in the `run_scenario` method
3. Update the documentation with the new action

### Custom Validation

Extend the `PostgreSQLClient` class to add custom validation methods for specific use cases.

### Additional Metrics

Add new metrics collection by extending the `test_performance_metrics` method.

## Security Considerations

- Store API credentials securely and never commit them to version control
- Use environment variables or secure credential management systems
- Limit API token permissions to only required operations
- Monitor test activities for unexpected resource usage
- Test firewall rules carefully to avoid blocking legitimate access

## Best Practices

1. **Start Small**: Begin with basic scenarios before running comprehensive tests
2. **Monitor Resources**: Watch for quota limits and resource consumption
3. **Cleanup Verification**: Ensure all test databases are properly cleaned up
4. **Parallel Limits**: Don't exceed API rate limits with too many parallel tests
5. **Test Isolation**: Each scenario should be independent and self-contained

## Contributing

1. Fork the repository
2. Create a feature branch
3. Add tests for new functionality
4. Submit a pull request with detailed description

## License

This project is licensed under the same terms as the Ubicloud project.
