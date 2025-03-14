# Ubicloud::VirtualMachineApi

All URIs are relative to *https://api.ubicloud.com*

| Method | HTTP request | Description |
| ------ | ------------ | ----------- |
| [**create_vm**](VirtualMachineApi.md#create_vm) | **POST** /project/{project_id}/location/{location}/vm/{vm_name} | Create a new VM in a specific location of a project |
| [**delete_vm**](VirtualMachineApi.md#delete_vm) | **DELETE** /project/{project_id}/location/{location}/vm/{vm_name} | Delete a specific VM |
| [**get_vm_details**](VirtualMachineApi.md#get_vm_details) | **GET** /project/{project_id}/location/{location}/vm/{vm_name} | Get details of a specific VM in a location |
| [**list_location_vms**](VirtualMachineApi.md#list_location_vms) | **GET** /project/{project_id}/location/{location}/vm | List VMs in a specific location of a project |
| [**list_project_vms**](VirtualMachineApi.md#list_project_vms) | **GET** /project/{project_id}/vm | List all VMs created under the given project ID and visible to logged in user |
| [**restart_vm**](VirtualMachineApi.md#restart_vm) | **POST** /project/{project_id}/location/{location}/vm/{vm_name}/restart | Restart a specific VM |


## create_vm

> <GetVMDetails200Response> create_vm(project_id, location, vm_name, create_vm_request)

Create a new VM in a specific location of a project

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::VirtualMachineApi.new
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project
location = 'eu-central-h1' # String | The Ubicloud location/region
vm_name = 'vm_name_example' # String | Virtual machine name
create_vm_request = Ubicloud::CreateVMRequest.new({public_key: 'public_key_example'}) # CreateVMRequest | 

begin
  # Create a new VM in a specific location of a project
  result = api_instance.create_vm(project_id, location, vm_name, create_vm_request)
  p result
rescue Ubicloud::ApiError => e
  puts "Error when calling VirtualMachineApi->create_vm: #{e}"
end
```

#### Using the create_vm_with_http_info variant

This returns an Array which contains the response data, status code and headers.

> <Array(<GetVMDetails200Response>, Integer, Hash)> create_vm_with_http_info(project_id, location, vm_name, create_vm_request)

```ruby
begin
  # Create a new VM in a specific location of a project
  data, status_code, headers = api_instance.create_vm_with_http_info(project_id, location, vm_name, create_vm_request)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => <GetVMDetails200Response>
rescue Ubicloud::ApiError => e
  puts "Error when calling VirtualMachineApi->create_vm_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **project_id** | **String** | ID of the project |  |
| **location** | **String** | The Ubicloud location/region |  |
| **vm_name** | **String** | Virtual machine name |  |
| **create_vm_request** | [**CreateVMRequest**](CreateVMRequest.md) |  |  |

### Return type

[**GetVMDetails200Response**](GetVMDetails200Response.md)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: application/json
- **Accept**: application/json


## delete_vm

> delete_vm(project_id, location, vm_name)

Delete a specific VM

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::VirtualMachineApi.new
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project
location = 'eu-central-h1' # String | The Ubicloud location/region
vm_name = 'vm_name_example' # String | Virtual machine name

begin
  # Delete a specific VM
  api_instance.delete_vm(project_id, location, vm_name)
rescue Ubicloud::ApiError => e
  puts "Error when calling VirtualMachineApi->delete_vm: #{e}"
end
```

#### Using the delete_vm_with_http_info variant

This returns an Array which contains the response data (`nil` in this case), status code and headers.

> <Array(nil, Integer, Hash)> delete_vm_with_http_info(project_id, location, vm_name)

```ruby
begin
  # Delete a specific VM
  data, status_code, headers = api_instance.delete_vm_with_http_info(project_id, location, vm_name)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => nil
rescue Ubicloud::ApiError => e
  puts "Error when calling VirtualMachineApi->delete_vm_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **project_id** | **String** | ID of the project |  |
| **location** | **String** | The Ubicloud location/region |  |
| **vm_name** | **String** | Virtual machine name |  |

### Return type

nil (empty response body)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: Not defined
- **Accept**: application/json


## get_vm_details

> <GetVMDetails200Response> get_vm_details(project_id, location, vm_name)

Get details of a specific VM in a location

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::VirtualMachineApi.new
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project
location = 'eu-central-h1' # String | The Ubicloud location/region
vm_name = 'vm_name_example' # String | Virtual machine name

begin
  # Get details of a specific VM in a location
  result = api_instance.get_vm_details(project_id, location, vm_name)
  p result
rescue Ubicloud::ApiError => e
  puts "Error when calling VirtualMachineApi->get_vm_details: #{e}"
end
```

#### Using the get_vm_details_with_http_info variant

This returns an Array which contains the response data, status code and headers.

> <Array(<GetVMDetails200Response>, Integer, Hash)> get_vm_details_with_http_info(project_id, location, vm_name)

```ruby
begin
  # Get details of a specific VM in a location
  data, status_code, headers = api_instance.get_vm_details_with_http_info(project_id, location, vm_name)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => <GetVMDetails200Response>
rescue Ubicloud::ApiError => e
  puts "Error when calling VirtualMachineApi->get_vm_details_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **project_id** | **String** | ID of the project |  |
| **location** | **String** | The Ubicloud location/region |  |
| **vm_name** | **String** | Virtual machine name |  |

### Return type

[**GetVMDetails200Response**](GetVMDetails200Response.md)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: Not defined
- **Accept**: application/json


## list_location_vms

> <ListLocationVMs200Response> list_location_vms(location, project_id, opts)

List VMs in a specific location of a project

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::VirtualMachineApi.new
location = 'eu-central-h1' # String | The Ubicloud location/region
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project
opts = {
  start_after: 'start_after_example', # String | Pagination - Start after
  page_size: 56, # Integer | Pagination - Page size
  order_column: 'order_column_example' # String | Pagination - Order column
}

begin
  # List VMs in a specific location of a project
  result = api_instance.list_location_vms(location, project_id, opts)
  p result
rescue Ubicloud::ApiError => e
  puts "Error when calling VirtualMachineApi->list_location_vms: #{e}"
end
```

#### Using the list_location_vms_with_http_info variant

This returns an Array which contains the response data, status code and headers.

> <Array(<ListLocationVMs200Response>, Integer, Hash)> list_location_vms_with_http_info(location, project_id, opts)

```ruby
begin
  # List VMs in a specific location of a project
  data, status_code, headers = api_instance.list_location_vms_with_http_info(location, project_id, opts)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => <ListLocationVMs200Response>
rescue Ubicloud::ApiError => e
  puts "Error when calling VirtualMachineApi->list_location_vms_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **location** | **String** | The Ubicloud location/region |  |
| **project_id** | **String** | ID of the project |  |
| **start_after** | **String** | Pagination - Start after | [optional] |
| **page_size** | **Integer** | Pagination - Page size | [optional][default to 10] |
| **order_column** | **String** | Pagination - Order column | [optional][default to &#39;id&#39;] |

### Return type

[**ListLocationVMs200Response**](ListLocationVMs200Response.md)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: Not defined
- **Accept**: application/json


## list_project_vms

> <ListLocationVMs200Response> list_project_vms(project_id, opts)

List all VMs created under the given project ID and visible to logged in user

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::VirtualMachineApi.new
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project
opts = {
  start_after: 'start_after_example', # String | Pagination - Start after
  page_size: 56, # Integer | Pagination - Page size
  order_column: 'order_column_example' # String | Pagination - Order column
}

begin
  # List all VMs created under the given project ID and visible to logged in user
  result = api_instance.list_project_vms(project_id, opts)
  p result
rescue Ubicloud::ApiError => e
  puts "Error when calling VirtualMachineApi->list_project_vms: #{e}"
end
```

#### Using the list_project_vms_with_http_info variant

This returns an Array which contains the response data, status code and headers.

> <Array(<ListLocationVMs200Response>, Integer, Hash)> list_project_vms_with_http_info(project_id, opts)

```ruby
begin
  # List all VMs created under the given project ID and visible to logged in user
  data, status_code, headers = api_instance.list_project_vms_with_http_info(project_id, opts)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => <ListLocationVMs200Response>
rescue Ubicloud::ApiError => e
  puts "Error when calling VirtualMachineApi->list_project_vms_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **project_id** | **String** | ID of the project |  |
| **start_after** | **String** | Pagination - Start after | [optional] |
| **page_size** | **Integer** | Pagination - Page size | [optional][default to 10] |
| **order_column** | **String** | Pagination - Order column | [optional][default to &#39;id&#39;] |

### Return type

[**ListLocationVMs200Response**](ListLocationVMs200Response.md)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: Not defined
- **Accept**: application/json


## restart_vm

> <GetVMDetails200Response> restart_vm(project_id, location, vm_name)

Restart a specific VM

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::VirtualMachineApi.new
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project
location = 'eu-central-h1' # String | The Ubicloud location/region
vm_name = 'vm_name_example' # String | Virtual machine name

begin
  # Restart a specific VM
  result = api_instance.restart_vm(project_id, location, vm_name)
  p result
rescue Ubicloud::ApiError => e
  puts "Error when calling VirtualMachineApi->restart_vm: #{e}"
end
```

#### Using the restart_vm_with_http_info variant

This returns an Array which contains the response data, status code and headers.

> <Array(<GetVMDetails200Response>, Integer, Hash)> restart_vm_with_http_info(project_id, location, vm_name)

```ruby
begin
  # Restart a specific VM
  data, status_code, headers = api_instance.restart_vm_with_http_info(project_id, location, vm_name)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => <GetVMDetails200Response>
rescue Ubicloud::ApiError => e
  puts "Error when calling VirtualMachineApi->restart_vm_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **project_id** | **String** | ID of the project |  |
| **location** | **String** | The Ubicloud location/region |  |
| **vm_name** | **String** | Virtual machine name |  |

### Return type

[**GetVMDetails200Response**](GetVMDetails200Response.md)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: Not defined
- **Accept**: application/json

