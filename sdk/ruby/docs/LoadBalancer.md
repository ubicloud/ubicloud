# Ubicloud::LoadBalancer

## Properties

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **algorithm** | **String** | Algorithm of the Load Balancer |  |
| **stack** | **String** | Networking stack of the Load Balancer (ipv4, ipv6, or dual) | [optional] |
| **dst_port** | **Integer** | Destination port for the Load Balancer |  |
| **health_check_endpoint** | **String** | Health check endpoint URL |  |
| **health_check_protocol** | **String** | Health check endpoint protocol |  |
| **hostname** | **String** | Hostname of the Load Balancer |  |
| **id** | **String** | ID of the Load Balancer |  |
| **location** | **String** | Location of the Load Balancer | [optional] |
| **name** | **String** | Name of the Load Balancer |  |
| **src_port** | **Integer** | Source port for the Load Balancer |  |

## Example

```ruby
require 'ubicloud-sdk'

instance = Ubicloud::LoadBalancer.new(
  algorithm: null,
  stack: null,
  dst_port: null,
  health_check_endpoint: null,
  health_check_protocol: null,
  hostname: null,
  id: 1bhw8r4pn73t1m5f7rn7a5pej2,
  location: null,
  name: null,
  src_port: null
)
```

