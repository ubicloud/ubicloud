# Ubicloud::PostgresDatabase

## Properties

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **flavor** | **String** | Kind of Postgres database |  |
| **ha_type** | **String** | High availability type |  |
| **id** | **String** | ID of the Postgres database |  |
| **location** | **String** | Location of the Postgres database |  |
| **name** | **String** | Name of the Postgres database |  |
| **state** | **String** | State of the Postgres database |  |
| **storage_size_gib** | **Integer** | Storage size in GiB |  |
| **version** | **String** | Postgres version |  |
| **vm_size** | **String** | Size of the underlying VM |  |
| **ca_certificates** | **String** | CA certificates of the root CA used to issue postgres server certificates | [optional] |

## Example

```ruby
require 'ubicloud-sdk'

instance = Ubicloud::PostgresDatabase.new(
  flavor: null,
  ha_type: null,
  id: pgn30gjk1d1e2jj34v9x0dq4rp,
  location: null,
  name: null,
  state: null,
  storage_size_gib: null,
  version: null,
  vm_size: null,
  ca_certificates: null
)
```

