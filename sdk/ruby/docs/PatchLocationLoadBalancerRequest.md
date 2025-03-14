# Ubicloud::PatchLocationLoadBalancerRequest

## Properties

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **algorithm** | **String** | Algorithm of the Load Balancer | [optional] |
| **stack** | **String** | Networking stack of the Load Balancer (ipv4, ipv6, or dual) | [optional] |
| **dst_port** | **Integer** | Destination port for the Load Balancer | [optional] |
| **health_check_endpoint** | **String** | Health check endpoint URL | [optional] |
| **src_port** | **Integer** | Source port for the Load Balancer | [optional] |
| **vms** | **Array&lt;String&gt;** | List of VM apids for the Load Balancer | [optional] |

## Example

```ruby
require 'ubicloud-sdk'

instance = Ubicloud::PatchLocationLoadBalancerRequest.new(
  algorithm: null,
  stack: null,
  dst_port: null,
  health_check_endpoint: null,
  src_port: null,
  vms: null
)
```

