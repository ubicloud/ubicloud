# Ubicloud::PostgresMetricDestinationApi

All URIs are relative to *https://api.ubicloud.com*

| Method | HTTP request | Description |
| ------ | ------------ | ----------- |
| [**create_location_postgres_metric_destination**](PostgresMetricDestinationApi.md#create_location_postgres_metric_destination) | **POST** /project/{project_id}/location/{location}/postgres/{postgres_database_name}/metric-destination | Create a new Postgres Metric Destination |
| [**delete_location_postgres_metric_destination**](PostgresMetricDestinationApi.md#delete_location_postgres_metric_destination) | **DELETE** /project/{project_id}/location/{location}/postgres/{postgres_database_name}/metric-destination/{metric_destination_id} | Delete a specific Metric Destination |


## create_location_postgres_metric_destination

> <GetPostgresDatabaseDetails200Response> create_location_postgres_metric_destination(location, postgres_database_name, project_id, create_location_postgres_metric_destination_request)

Create a new Postgres Metric Destination

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::PostgresMetricDestinationApi.new
location = 'eu-central-h1' # String | The Ubicloud location/region
postgres_database_name = 'postgres_database_name_example' # String | Postgres database name
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project
create_location_postgres_metric_destination_request = Ubicloud::CreateLocationPostgresMetricDestinationRequest.new({password: 'password_example', url: 'url_example', username: 'username_example'}) # CreateLocationPostgresMetricDestinationRequest | 

begin
  # Create a new Postgres Metric Destination
  result = api_instance.create_location_postgres_metric_destination(location, postgres_database_name, project_id, create_location_postgres_metric_destination_request)
  p result
rescue Ubicloud::ApiError => e
  puts "Error when calling PostgresMetricDestinationApi->create_location_postgres_metric_destination: #{e}"
end
```

#### Using the create_location_postgres_metric_destination_with_http_info variant

This returns an Array which contains the response data, status code and headers.

> <Array(<GetPostgresDatabaseDetails200Response>, Integer, Hash)> create_location_postgres_metric_destination_with_http_info(location, postgres_database_name, project_id, create_location_postgres_metric_destination_request)

```ruby
begin
  # Create a new Postgres Metric Destination
  data, status_code, headers = api_instance.create_location_postgres_metric_destination_with_http_info(location, postgres_database_name, project_id, create_location_postgres_metric_destination_request)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => <GetPostgresDatabaseDetails200Response>
rescue Ubicloud::ApiError => e
  puts "Error when calling PostgresMetricDestinationApi->create_location_postgres_metric_destination_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **location** | **String** | The Ubicloud location/region |  |
| **postgres_database_name** | **String** | Postgres database name |  |
| **project_id** | **String** | ID of the project |  |
| **create_location_postgres_metric_destination_request** | [**CreateLocationPostgresMetricDestinationRequest**](CreateLocationPostgresMetricDestinationRequest.md) |  |  |

### Return type

[**GetPostgresDatabaseDetails200Response**](GetPostgresDatabaseDetails200Response.md)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: application/json
- **Accept**: application/json


## delete_location_postgres_metric_destination

> delete_location_postgres_metric_destination(location, metric_destination_id, postgres_database_name, project_id)

Delete a specific Metric Destination

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::PostgresMetricDestinationApi.new
location = 'eu-central-h1' # String | The Ubicloud location/region
metric_destination_id = 'et7ekmf54nae5nya9s6vebg43f' # String | Postgres Metric Destination ID
postgres_database_name = 'postgres_database_name_example' # String | Postgres database name
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project

begin
  # Delete a specific Metric Destination
  api_instance.delete_location_postgres_metric_destination(location, metric_destination_id, postgres_database_name, project_id)
rescue Ubicloud::ApiError => e
  puts "Error when calling PostgresMetricDestinationApi->delete_location_postgres_metric_destination: #{e}"
end
```

#### Using the delete_location_postgres_metric_destination_with_http_info variant

This returns an Array which contains the response data (`nil` in this case), status code and headers.

> <Array(nil, Integer, Hash)> delete_location_postgres_metric_destination_with_http_info(location, metric_destination_id, postgres_database_name, project_id)

```ruby
begin
  # Delete a specific Metric Destination
  data, status_code, headers = api_instance.delete_location_postgres_metric_destination_with_http_info(location, metric_destination_id, postgres_database_name, project_id)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => nil
rescue Ubicloud::ApiError => e
  puts "Error when calling PostgresMetricDestinationApi->delete_location_postgres_metric_destination_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **location** | **String** | The Ubicloud location/region |  |
| **metric_destination_id** | **String** | Postgres Metric Destination ID |  |
| **postgres_database_name** | **String** | Postgres database name |  |
| **project_id** | **String** | ID of the project |  |

### Return type

nil (empty response body)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: Not defined
- **Accept**: application/json

