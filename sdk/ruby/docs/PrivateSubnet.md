# Ubicloud::PrivateSubnet

## Properties

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **firewalls** | [**Array&lt;Firewall&gt;**](Firewall.md) |  |  |
| **id** | **String** | ID of the subnet |  |
| **location** | **String** | Location of the subnet |  |
| **name** | **String** | Name of the subnet |  |
| **net4** | **String** | IPv4 CIDR of the subnet |  |
| **net6** | **String** | IPv6 CIDR of the subnet |  |
| **nics** | [**Array&lt;Nic&gt;**](Nic.md) | List of NICs |  |
| **state** | **String** | State of the subnet |  |

## Example

```ruby
require 'ubicloud-sdk'

instance = Ubicloud::PrivateSubnet.new(
  firewalls: null,
  id: ps3dngttwvje2kmr2sn8x12x4r,
  location: null,
  name: null,
  net4: null,
  net6: null,
  nics: null,
  state: null
)
```

