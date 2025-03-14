# Ubicloud::Nic

## Properties

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **id** | **String** | ID of the NIC |  |
| **name** | **String** | Name of the NIC |  |
| **private_ipv4** | **String** | Private IPv4 address |  |
| **private_ipv6** | **String** | Private IPv6 address |  |
| **vm_name** | **String** | Name of the VM |  |

## Example

```ruby
require 'ubicloud-sdk'

instance = Ubicloud::Nic.new(
  id: null,
  name: null,
  private_ipv4: null,
  private_ipv6: null,
  vm_name: null
)
```

