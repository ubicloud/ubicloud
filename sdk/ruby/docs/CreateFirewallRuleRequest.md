# Ubicloud::CreateFirewallRuleRequest

## Properties

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **cidr** | **String** | CIDR of the firewall rule |  |
| **firewall_id** | **String** |  | [optional] |
| **port_range** | **String** | Port range of the firewall rule | [optional] |
| **project_id** | **String** |  | [optional] |

## Example

```ruby
require 'ubicloud-sdk'

instance = Ubicloud::CreateFirewallRuleRequest.new(
  cidr: null,
  firewall_id: null,
  port_range: null,
  project_id: null
)
```

