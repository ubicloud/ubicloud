# Ubicloud::CreateLoadBalancerRequest

## Properties

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **algorithm** | **String** | Algorithm of the Load Balancer |  |
| **stack** | **String** | Networking stack of the Load Balancer (ipv4, ipv6, or dual) | [optional] |
| **dst_port** | **Integer** | Destination port for the Load Balancer |  |
| **health_check_endpoint** | **String** | Health check endpoint URL | [optional] |
| **health_check_protocol** | **String** | Health check endpoint protocol |  |
| **private_subnet_id** | **String** | ID of Private Subnet |  |
| **src_port** | **Integer** | Source port for the Load Balancer |  |

## Example

```ruby
require 'ubicloud-sdk'

instance = Ubicloud::CreateLoadBalancerRequest.new(
  algorithm: null,
  stack: null,
  dst_port: null,
  health_check_endpoint: null,
  health_check_protocol: null,
  private_subnet_id: null,
  src_port: null
)
```

