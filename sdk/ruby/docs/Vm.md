# Ubicloud::Vm

## Properties

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **id** | **String** | ID of the VM |  |
| **ip4** | **String** | IPv4 address |  |
| **ip4_enabled** | **Boolean** | Whether IPv4 is enabled |  |
| **ip6** | **String** | IPv6 address |  |
| **location** | **String** | Location of the VM |  |
| **name** | **String** | Name of the VM |  |
| **size** | **String** | Size of the underlying VM |  |
| **state** | **String** | State of the VM |  |
| **storage_size_gib** | **Integer** | Storage size in GiB |  |
| **unix_user** | **String** | Unix user of the VM |  |

## Example

```ruby
require 'ubicloud-sdk'

instance = Ubicloud::Vm.new(
  id: vmhfy8gff8c67hasb0eez2k1pd,
  ip4: null,
  ip4_enabled: null,
  ip6: null,
  location: eu-central-h1,
  name: my-vm-name,
  size: null,
  state: null,
  storage_size_gib: null,
  unix_user: null
)
```

