# Ubicloud::GetLoadBalancer200Response

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
| **location** | **String** | Location of the Load Balancer |  |
| **name** | **String** | Name of the Load Balancer |  |
| **src_port** | **Integer** | Source port for the Load Balancer |  |
| **subnet** | **String** | Subnet of the Load Balancer |  |
| **vms** | [**Array&lt;Vm&gt;**](Vm.md) |  |  |

## Example

```ruby
require 'ubicloud-sdk'

instance = Ubicloud::GetLoadBalancer200Response.new(
  algorithm: null,
  stack: null,
  dst_port: null,
  health_check_endpoint: null,
  health_check_protocol: null,
  hostname: null,
  id: 1bhw8r4pn73t1m5f7rn7a5pej2,
  location: null,
  name: null,
  src_port: null,
  subnet: null,
  vms: null
)
```

