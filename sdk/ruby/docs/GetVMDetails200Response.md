# Ubicloud::GetVMDetails200Response

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
| **firewalls** | [**Array&lt;Firewall&gt;**](Firewall.md) | List of firewalls |  |
| **private_ipv4** | **String** | Private IPv4 address |  |
| **private_ipv6** | **String** | Private IPv6 address |  |
| **subnet** | **String** | Subnet of the VM |  |

## Example

```ruby
require 'ubicloud-sdk'

instance = Ubicloud::GetVMDetails200Response.new(
  id: vmhfy8gff8c67hasb0eez2k1pd,
  ip4: null,
  ip4_enabled: null,
  ip6: null,
  location: eu-central-h1,
  name: my-vm-name,
  size: null,
  state: null,
  storage_size_gib: null,
  unix_user: null,
  firewalls: null,
  private_ipv4: null,
  private_ipv6: null,
  subnet: null
)
```

