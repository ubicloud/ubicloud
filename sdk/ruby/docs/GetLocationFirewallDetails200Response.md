# Ubicloud::GetLocationFirewallDetails200Response

## Properties

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **description** | **String** | Description of the firewall |  |
| **firewall_rules** | [**Array&lt;FirewallRule&gt;**](FirewallRule.md) | List of firewall rules |  |
| **id** | **String** | ID of the firewall |  |
| **location** | **String** | Location of the the firewall |  |
| **name** | **String** | Name of the firewall |  |
| **private_subnets** | **Array&lt;String&gt;** | List of private subnets |  |

## Example

```ruby
require 'ubicloud-sdk'

instance = Ubicloud::GetLocationFirewallDetails200Response.new(
  description: null,
  firewall_rules: null,
  id: fwfg7td83em22qfw9pq5xyfqb7,
  location: null,
  name: null,
  private_subnets: null
)
```

