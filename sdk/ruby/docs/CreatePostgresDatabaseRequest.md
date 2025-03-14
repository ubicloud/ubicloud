# Ubicloud::CreatePostgresDatabaseRequest

## Properties

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **flavor** | **String** | Kind of database | [optional] |
| **ha_type** | **String** | High availability type | [optional] |
| **size** | **String** | Requested size for the underlying VM |  |
| **storage_size** | **Integer** | Requested storage size in GiB | [optional] |
| **version** | **String** | PostgreSQL version | [optional] |

## Example

```ruby
require 'ubicloud-sdk'

instance = Ubicloud::CreatePostgresDatabaseRequest.new(
  flavor: null,
  ha_type: null,
  size: null,
  storage_size: null,
  version: null
)
```

