# Ubicloud::Firewall

## Properties

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **description** | **String** | Description of the firewall |  |
| **firewall_rules** | [**Array&lt;FirewallRule&gt;**](FirewallRule.md) | List of firewall rules |  |
| **id** | **String** | ID of the firewall |  |
| **location** | **String** | Location of the the firewall |  |
| **name** | **String** | Name of the firewall |  |

## Example

```ruby
require 'ubicloud-sdk'

instance = Ubicloud::Firewall.new(
  description: null,
  firewall_rules: null,
  id: fwfg7td83em22qfw9pq5xyfqb7,
  location: null,
  name: null
)
```

