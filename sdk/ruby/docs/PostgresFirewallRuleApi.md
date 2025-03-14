# Ubicloud::PostgresFirewallRuleApi

All URIs are relative to *https://api.ubicloud.com*

| Method | HTTP request | Description |
| ------ | ------------ | ----------- |
| [**create_location_postgres_firewall_rule**](PostgresFirewallRuleApi.md#create_location_postgres_firewall_rule) | **POST** /project/{project_id}/location/{location}/postgres/{postgres_database_name}/firewall-rule | Create a new postgres firewall rule |
| [**list_location_postgres_firewall_rules**](PostgresFirewallRuleApi.md#list_location_postgres_firewall_rules) | **GET** /project/{project_id}/location/{location}/postgres/{postgres_database_name}/firewall-rule | List location Postgres firewall rules |


## create_location_postgres_firewall_rule

> <PostgresFirewallRule> create_location_postgres_firewall_rule(location, postgres_database_name, project_id, create_location_postgres_firewall_rule_request)

Create a new postgres firewall rule

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::PostgresFirewallRuleApi.new
location = 'eu-central-h1' # String | The Ubicloud location/region
postgres_database_name = 'postgres_database_name_example' # String | Postgres database name
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project
create_location_postgres_firewall_rule_request = Ubicloud::CreateLocationPostgresFirewallRuleRequest.new({cidr: 'cidr_example'}) # CreateLocationPostgresFirewallRuleRequest | 

begin
  # Create a new postgres firewall rule
  result = api_instance.create_location_postgres_firewall_rule(location, postgres_database_name, project_id, create_location_postgres_firewall_rule_request)
  p result
rescue Ubicloud::ApiError => e
  puts "Error when calling PostgresFirewallRuleApi->create_location_postgres_firewall_rule: #{e}"
end
```

#### Using the create_location_postgres_firewall_rule_with_http_info variant

This returns an Array which contains the response data, status code and headers.

> <Array(<PostgresFirewallRule>, Integer, Hash)> create_location_postgres_firewall_rule_with_http_info(location, postgres_database_name, project_id, create_location_postgres_firewall_rule_request)

```ruby
begin
  # Create a new postgres firewall rule
  data, status_code, headers = api_instance.create_location_postgres_firewall_rule_with_http_info(location, postgres_database_name, project_id, create_location_postgres_firewall_rule_request)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => <PostgresFirewallRule>
rescue Ubicloud::ApiError => e
  puts "Error when calling PostgresFirewallRuleApi->create_location_postgres_firewall_rule_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **location** | **String** | The Ubicloud location/region |  |
| **postgres_database_name** | **String** | Postgres database name |  |
| **project_id** | **String** | ID of the project |  |
| **create_location_postgres_firewall_rule_request** | [**CreateLocationPostgresFirewallRuleRequest**](CreateLocationPostgresFirewallRuleRequest.md) |  |  |

### Return type

[**PostgresFirewallRule**](PostgresFirewallRule.md)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: application/json
- **Accept**: application/json


## list_location_postgres_firewall_rules

> <ListLocationPostgresFirewallRules200Response> list_location_postgres_firewall_rules(location, postgres_database_name, project_id)

List location Postgres firewall rules

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::PostgresFirewallRuleApi.new
location = 'eu-central-h1' # String | The Ubicloud location/region
postgres_database_name = 'postgres_database_name_example' # String | Postgres database name
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project

begin
  # List location Postgres firewall rules
  result = api_instance.list_location_postgres_firewall_rules(location, postgres_database_name, project_id)
  p result
rescue Ubicloud::ApiError => e
  puts "Error when calling PostgresFirewallRuleApi->list_location_postgres_firewall_rules: #{e}"
end
```

#### Using the list_location_postgres_firewall_rules_with_http_info variant

This returns an Array which contains the response data, status code and headers.

> <Array(<ListLocationPostgresFirewallRules200Response>, Integer, Hash)> list_location_postgres_firewall_rules_with_http_info(location, postgres_database_name, project_id)

```ruby
begin
  # List location Postgres firewall rules
  data, status_code, headers = api_instance.list_location_postgres_firewall_rules_with_http_info(location, postgres_database_name, project_id)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => <ListLocationPostgresFirewallRules200Response>
rescue Ubicloud::ApiError => e
  puts "Error when calling PostgresFirewallRuleApi->list_location_postgres_firewall_rules_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **location** | **String** | The Ubicloud location/region |  |
| **postgres_database_name** | **String** | Postgres database name |  |
| **project_id** | **String** | ID of the project |  |

### Return type

[**ListLocationPostgresFirewallRules200Response**](ListLocationPostgresFirewallRules200Response.md)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: Not defined
- **Accept**: application/json

