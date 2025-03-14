# Ubicloud::PostgresDatabaseApi

All URIs are relative to *https://api.ubicloud.com*

| Method | HTTP request | Description |
| ------ | ------------ | ----------- |
| [**create_postgres_database**](PostgresDatabaseApi.md#create_postgres_database) | **POST** /project/{project_id}/location/{location}/postgres/{postgres_database_name} | Create a new Postgres Database in a specific location of a project |
| [**delete_postgres_database**](PostgresDatabaseApi.md#delete_postgres_database) | **DELETE** /project/{project_id}/location/{location}/postgres/{postgres_database_name} | Delete a specific Postgres Database |
| [**get_postgres_ca_certificates_by_name**](PostgresDatabaseApi.md#get_postgres_ca_certificates_by_name) | **GET** /project/{project_id}/location/{location}/postgres/{postgres_database_name}/ca-certificates | Download CA certificates for a specific Postgres Database in a location with name |
| [**get_postgres_database_details**](PostgresDatabaseApi.md#get_postgres_database_details) | **GET** /project/{project_id}/location/{location}/postgres/{postgres_database_name} | Get details of a specific Postgres database in a location |
| [**list_location_postgres_databases**](PostgresDatabaseApi.md#list_location_postgres_databases) | **GET** /project/{project_id}/location/{location}/postgres | List Postgres Databases in a specific location of a project |
| [**list_postgres_databases**](PostgresDatabaseApi.md#list_postgres_databases) | **GET** /project/{project_id}/postgres | List visible Postgres Databases |
| [**reset_superuser_password**](PostgresDatabaseApi.md#reset_superuser_password) | **POST** /project/{project_id}/location/{location}/postgres/{postgres_database_name}/reset-superuser-password | Reset superuser password of the Postgres database |
| [**restart_postgres_database**](PostgresDatabaseApi.md#restart_postgres_database) | **POST** /project/{project_id}/location/{location}/postgres/{postgres_database_name}/restart | Restart a specific Postgres Database |
| [**restore_postgres_database**](PostgresDatabaseApi.md#restore_postgres_database) | **POST** /project/{project_id}/location/{location}/postgres/{postgres_database_name}/restore | Restore a new Postgres database in a specific location of a project |


## create_postgres_database

> <GetPostgresDatabaseDetails200Response> create_postgres_database(project_id, location, postgres_database_name, create_postgres_database_request)

Create a new Postgres Database in a specific location of a project

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::PostgresDatabaseApi.new
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project
location = 'eu-central-h1' # String | The Ubicloud location/region
postgres_database_name = 'postgres_database_name_example' # String | Postgres database name
create_postgres_database_request = Ubicloud::CreatePostgresDatabaseRequest.new({size: 'size_example'}) # CreatePostgresDatabaseRequest | 

begin
  # Create a new Postgres Database in a specific location of a project
  result = api_instance.create_postgres_database(project_id, location, postgres_database_name, create_postgres_database_request)
  p result
rescue Ubicloud::ApiError => e
  puts "Error when calling PostgresDatabaseApi->create_postgres_database: #{e}"
end
```

#### Using the create_postgres_database_with_http_info variant

This returns an Array which contains the response data, status code and headers.

> <Array(<GetPostgresDatabaseDetails200Response>, Integer, Hash)> create_postgres_database_with_http_info(project_id, location, postgres_database_name, create_postgres_database_request)

```ruby
begin
  # Create a new Postgres Database in a specific location of a project
  data, status_code, headers = api_instance.create_postgres_database_with_http_info(project_id, location, postgres_database_name, create_postgres_database_request)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => <GetPostgresDatabaseDetails200Response>
rescue Ubicloud::ApiError => e
  puts "Error when calling PostgresDatabaseApi->create_postgres_database_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **project_id** | **String** | ID of the project |  |
| **location** | **String** | The Ubicloud location/region |  |
| **postgres_database_name** | **String** | Postgres database name |  |
| **create_postgres_database_request** | [**CreatePostgresDatabaseRequest**](CreatePostgresDatabaseRequest.md) |  |  |

### Return type

[**GetPostgresDatabaseDetails200Response**](GetPostgresDatabaseDetails200Response.md)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: application/json
- **Accept**: application/json


## delete_postgres_database

> delete_postgres_database(project_id, location, postgres_database_name)

Delete a specific Postgres Database

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::PostgresDatabaseApi.new
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project
location = 'eu-central-h1' # String | The Ubicloud location/region
postgres_database_name = 'postgres_database_name_example' # String | Postgres database name

begin
  # Delete a specific Postgres Database
  api_instance.delete_postgres_database(project_id, location, postgres_database_name)
rescue Ubicloud::ApiError => e
  puts "Error when calling PostgresDatabaseApi->delete_postgres_database: #{e}"
end
```

#### Using the delete_postgres_database_with_http_info variant

This returns an Array which contains the response data (`nil` in this case), status code and headers.

> <Array(nil, Integer, Hash)> delete_postgres_database_with_http_info(project_id, location, postgres_database_name)

```ruby
begin
  # Delete a specific Postgres Database
  data, status_code, headers = api_instance.delete_postgres_database_with_http_info(project_id, location, postgres_database_name)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => nil
rescue Ubicloud::ApiError => e
  puts "Error when calling PostgresDatabaseApi->delete_postgres_database_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **project_id** | **String** | ID of the project |  |
| **location** | **String** | The Ubicloud location/region |  |
| **postgres_database_name** | **String** | Postgres database name |  |

### Return type

nil (empty response body)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: Not defined
- **Accept**: application/json


## get_postgres_ca_certificates_by_name

> File get_postgres_ca_certificates_by_name(project_id, location, postgres_database_name)

Download CA certificates for a specific Postgres Database in a location with name

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::PostgresDatabaseApi.new
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project
location = 'eu-central-h1' # String | The Ubicloud location/region
postgres_database_name = 'postgres_database_name_example' # String | Postgres database name

begin
  # Download CA certificates for a specific Postgres Database in a location with name
  result = api_instance.get_postgres_ca_certificates_by_name(project_id, location, postgres_database_name)
  p result
rescue Ubicloud::ApiError => e
  puts "Error when calling PostgresDatabaseApi->get_postgres_ca_certificates_by_name: #{e}"
end
```

#### Using the get_postgres_ca_certificates_by_name_with_http_info variant

This returns an Array which contains the response data, status code and headers.

> <Array(File, Integer, Hash)> get_postgres_ca_certificates_by_name_with_http_info(project_id, location, postgres_database_name)

```ruby
begin
  # Download CA certificates for a specific Postgres Database in a location with name
  data, status_code, headers = api_instance.get_postgres_ca_certificates_by_name_with_http_info(project_id, location, postgres_database_name)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => File
rescue Ubicloud::ApiError => e
  puts "Error when calling PostgresDatabaseApi->get_postgres_ca_certificates_by_name_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **project_id** | **String** | ID of the project |  |
| **location** | **String** | The Ubicloud location/region |  |
| **postgres_database_name** | **String** | Postgres database name |  |

### Return type

**File**

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: Not defined
- **Accept**: application/x-pem-file, application/json


## get_postgres_database_details

> <GetPostgresDatabaseDetails200Response> get_postgres_database_details(project_id, location, postgres_database_name)

Get details of a specific Postgres database in a location

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::PostgresDatabaseApi.new
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project
location = 'eu-central-h1' # String | The Ubicloud location/region
postgres_database_name = 'postgres_database_name_example' # String | Postgres database name

begin
  # Get details of a specific Postgres database in a location
  result = api_instance.get_postgres_database_details(project_id, location, postgres_database_name)
  p result
rescue Ubicloud::ApiError => e
  puts "Error when calling PostgresDatabaseApi->get_postgres_database_details: #{e}"
end
```

#### Using the get_postgres_database_details_with_http_info variant

This returns an Array which contains the response data, status code and headers.

> <Array(<GetPostgresDatabaseDetails200Response>, Integer, Hash)> get_postgres_database_details_with_http_info(project_id, location, postgres_database_name)

```ruby
begin
  # Get details of a specific Postgres database in a location
  data, status_code, headers = api_instance.get_postgres_database_details_with_http_info(project_id, location, postgres_database_name)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => <GetPostgresDatabaseDetails200Response>
rescue Ubicloud::ApiError => e
  puts "Error when calling PostgresDatabaseApi->get_postgres_database_details_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **project_id** | **String** | ID of the project |  |
| **location** | **String** | The Ubicloud location/region |  |
| **postgres_database_name** | **String** | Postgres database name |  |

### Return type

[**GetPostgresDatabaseDetails200Response**](GetPostgresDatabaseDetails200Response.md)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: Not defined
- **Accept**: application/json


## list_location_postgres_databases

> <ListLocationPostgresDatabases200Response> list_location_postgres_databases(project_id, location, opts)

List Postgres Databases in a specific location of a project

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::PostgresDatabaseApi.new
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project
location = 'eu-central-h1' # String | The Ubicloud location/region
opts = {
  start_after: 'start_after_example', # String | Pagination - Start after
  page_size: 56, # Integer | Pagination - Page size
  order_column: 'order_column_example' # String | Pagination - Order column
}

begin
  # List Postgres Databases in a specific location of a project
  result = api_instance.list_location_postgres_databases(project_id, location, opts)
  p result
rescue Ubicloud::ApiError => e
  puts "Error when calling PostgresDatabaseApi->list_location_postgres_databases: #{e}"
end
```

#### Using the list_location_postgres_databases_with_http_info variant

This returns an Array which contains the response data, status code and headers.

> <Array(<ListLocationPostgresDatabases200Response>, Integer, Hash)> list_location_postgres_databases_with_http_info(project_id, location, opts)

```ruby
begin
  # List Postgres Databases in a specific location of a project
  data, status_code, headers = api_instance.list_location_postgres_databases_with_http_info(project_id, location, opts)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => <ListLocationPostgresDatabases200Response>
rescue Ubicloud::ApiError => e
  puts "Error when calling PostgresDatabaseApi->list_location_postgres_databases_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **project_id** | **String** | ID of the project |  |
| **location** | **String** | The Ubicloud location/region |  |
| **start_after** | **String** | Pagination - Start after | [optional] |
| **page_size** | **Integer** | Pagination - Page size | [optional][default to 10] |
| **order_column** | **String** | Pagination - Order column | [optional][default to &#39;id&#39;] |

### Return type

[**ListLocationPostgresDatabases200Response**](ListLocationPostgresDatabases200Response.md)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: Not defined
- **Accept**: application/json


## list_postgres_databases

> <ListLocationPostgresDatabases200Response> list_postgres_databases(project_id, opts)

List visible Postgres Databases

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::PostgresDatabaseApi.new
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project
opts = {
  start_after: 'start_after_example', # String | Pagination - Start after
  page_size: 56, # Integer | Pagination - Page size
  order_column: 'order_column_example' # String | Pagination - Order column
}

begin
  # List visible Postgres Databases
  result = api_instance.list_postgres_databases(project_id, opts)
  p result
rescue Ubicloud::ApiError => e
  puts "Error when calling PostgresDatabaseApi->list_postgres_databases: #{e}"
end
```

#### Using the list_postgres_databases_with_http_info variant

This returns an Array which contains the response data, status code and headers.

> <Array(<ListLocationPostgresDatabases200Response>, Integer, Hash)> list_postgres_databases_with_http_info(project_id, opts)

```ruby
begin
  # List visible Postgres Databases
  data, status_code, headers = api_instance.list_postgres_databases_with_http_info(project_id, opts)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => <ListLocationPostgresDatabases200Response>
rescue Ubicloud::ApiError => e
  puts "Error when calling PostgresDatabaseApi->list_postgres_databases_with_http_info: #{e}"
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

[**ListLocationPostgresDatabases200Response**](ListLocationPostgresDatabases200Response.md)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: Not defined
- **Accept**: application/json


## reset_superuser_password

> <GetPostgresDatabaseDetails200Response> reset_superuser_password(project_id, location, postgres_database_name, reset_superuser_password_request)

Reset superuser password of the Postgres database

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::PostgresDatabaseApi.new
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project
location = 'eu-central-h1' # String | The Ubicloud location/region
postgres_database_name = 'postgres_database_name_example' # String | Postgres database name
reset_superuser_password_request = Ubicloud::ResetSuperuserPasswordRequest.new({password: 'password_example'}) # ResetSuperuserPasswordRequest | 

begin
  # Reset superuser password of the Postgres database
  result = api_instance.reset_superuser_password(project_id, location, postgres_database_name, reset_superuser_password_request)
  p result
rescue Ubicloud::ApiError => e
  puts "Error when calling PostgresDatabaseApi->reset_superuser_password: #{e}"
end
```

#### Using the reset_superuser_password_with_http_info variant

This returns an Array which contains the response data, status code and headers.

> <Array(<GetPostgresDatabaseDetails200Response>, Integer, Hash)> reset_superuser_password_with_http_info(project_id, location, postgres_database_name, reset_superuser_password_request)

```ruby
begin
  # Reset superuser password of the Postgres database
  data, status_code, headers = api_instance.reset_superuser_password_with_http_info(project_id, location, postgres_database_name, reset_superuser_password_request)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => <GetPostgresDatabaseDetails200Response>
rescue Ubicloud::ApiError => e
  puts "Error when calling PostgresDatabaseApi->reset_superuser_password_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **project_id** | **String** | ID of the project |  |
| **location** | **String** | The Ubicloud location/region |  |
| **postgres_database_name** | **String** | Postgres database name |  |
| **reset_superuser_password_request** | [**ResetSuperuserPasswordRequest**](ResetSuperuserPasswordRequest.md) |  |  |

### Return type

[**GetPostgresDatabaseDetails200Response**](GetPostgresDatabaseDetails200Response.md)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: application/json
- **Accept**: application/json


## restart_postgres_database

> <GetPostgresDatabaseDetails200Response> restart_postgres_database(project_id, location, postgres_database_name)

Restart a specific Postgres Database

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::PostgresDatabaseApi.new
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project
location = 'eu-central-h1' # String | The Ubicloud location/region
postgres_database_name = 'postgres_database_name_example' # String | Postgres database name

begin
  # Restart a specific Postgres Database
  result = api_instance.restart_postgres_database(project_id, location, postgres_database_name)
  p result
rescue Ubicloud::ApiError => e
  puts "Error when calling PostgresDatabaseApi->restart_postgres_database: #{e}"
end
```

#### Using the restart_postgres_database_with_http_info variant

This returns an Array which contains the response data, status code and headers.

> <Array(<GetPostgresDatabaseDetails200Response>, Integer, Hash)> restart_postgres_database_with_http_info(project_id, location, postgres_database_name)

```ruby
begin
  # Restart a specific Postgres Database
  data, status_code, headers = api_instance.restart_postgres_database_with_http_info(project_id, location, postgres_database_name)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => <GetPostgresDatabaseDetails200Response>
rescue Ubicloud::ApiError => e
  puts "Error when calling PostgresDatabaseApi->restart_postgres_database_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **project_id** | **String** | ID of the project |  |
| **location** | **String** | The Ubicloud location/region |  |
| **postgres_database_name** | **String** | Postgres database name |  |

### Return type

[**GetPostgresDatabaseDetails200Response**](GetPostgresDatabaseDetails200Response.md)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: Not defined
- **Accept**: application/json


## restore_postgres_database

> <GetPostgresDatabaseDetails200Response> restore_postgres_database(project_id, location, postgres_database_name, restore_postgres_database_request)

Restore a new Postgres database in a specific location of a project

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::PostgresDatabaseApi.new
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project
location = 'eu-central-h1' # String | The Ubicloud location/region
postgres_database_name = 'postgres_database_name_example' # String | Postgres database name
restore_postgres_database_request = Ubicloud::RestorePostgresDatabaseRequest.new({name: 'name_example', restore_target: 'restore_target_example'}) # RestorePostgresDatabaseRequest | 

begin
  # Restore a new Postgres database in a specific location of a project
  result = api_instance.restore_postgres_database(project_id, location, postgres_database_name, restore_postgres_database_request)
  p result
rescue Ubicloud::ApiError => e
  puts "Error when calling PostgresDatabaseApi->restore_postgres_database: #{e}"
end
```

#### Using the restore_postgres_database_with_http_info variant

This returns an Array which contains the response data, status code and headers.

> <Array(<GetPostgresDatabaseDetails200Response>, Integer, Hash)> restore_postgres_database_with_http_info(project_id, location, postgres_database_name, restore_postgres_database_request)

```ruby
begin
  # Restore a new Postgres database in a specific location of a project
  data, status_code, headers = api_instance.restore_postgres_database_with_http_info(project_id, location, postgres_database_name, restore_postgres_database_request)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => <GetPostgresDatabaseDetails200Response>
rescue Ubicloud::ApiError => e
  puts "Error when calling PostgresDatabaseApi->restore_postgres_database_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **project_id** | **String** | ID of the project |  |
| **location** | **String** | The Ubicloud location/region |  |
| **postgres_database_name** | **String** | Postgres database name |  |
| **restore_postgres_database_request** | [**RestorePostgresDatabaseRequest**](RestorePostgresDatabaseRequest.md) |  |  |

### Return type

[**GetPostgresDatabaseDetails200Response**](GetPostgresDatabaseDetails200Response.md)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: application/json
- **Accept**: application/json

