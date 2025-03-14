# Ubicloud::CreateVMRequest

## Properties

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **boot_image** | **String** | Boot image of the VM | [optional] |
| **enable_ip4** | **Boolean** | Enable IPv4 | [optional] |
| **private_subnet_id** | **String** | ID of the private subnet | [optional] |
| **public_key** | **String** | Public SSH key for the VM |  |
| **size** | **String** | Size of the VM | [optional] |
| **storage_size** | **Integer** | Requested storage size in GiB | [optional] |
| **unix_user** | **String** | Unix user of the VM | [optional] |

## Example

```ruby
require 'ubicloud-sdk'

instance = Ubicloud::CreateVMRequest.new(
  boot_image: null,
  enable_ip4: null,
  private_subnet_id: null,
  public_key: null,
  size: null,
  storage_size: null,
  unix_user: null
)
```

