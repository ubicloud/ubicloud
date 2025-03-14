=begin
#Clover API

#API for managing resources on Ubicloud

The version of the OpenAPI document: 0.1.0
Contact: support@ubicloud.com
Generated by: https://openapi-generator.tech
Generator version: 7.12.0

=end

require 'spec_helper'
require 'json'

# Unit tests for Ubicloud::PostgresMetricDestinationApi
# Automatically generated by openapi-generator (https://openapi-generator.tech)
# Please update as you see appropriate
describe 'PostgresMetricDestinationApi' do
  before do
    # run before each test
    @api_instance = Ubicloud::PostgresMetricDestinationApi.new
  end

  after do
    # run after each test
  end

  describe 'test an instance of PostgresMetricDestinationApi' do
    it 'should create an instance of PostgresMetricDestinationApi' do
      expect(@api_instance).to be_instance_of(Ubicloud::PostgresMetricDestinationApi)
    end
  end

  # unit tests for create_location_postgres_metric_destination
  # Create a new Postgres Metric Destination
  # @param location The Ubicloud location/region
  # @param postgres_database_name Postgres database name
  # @param project_id ID of the project
  # @param create_location_postgres_metric_destination_request 
  # @param [Hash] opts the optional parameters
  # @return [GetPostgresDatabaseDetails200Response]
  describe 'create_location_postgres_metric_destination test' do
    it 'should work' do
      # assertion here. ref: https://rspec.info/features/3-12/rspec-expectations/built-in-matchers/
    end
  end

  # unit tests for delete_location_postgres_metric_destination
  # Delete a specific Metric Destination
  # @param location The Ubicloud location/region
  # @param metric_destination_id Postgres Metric Destination ID
  # @param postgres_database_name Postgres database name
  # @param project_id ID of the project
  # @param [Hash] opts the optional parameters
  # @return [nil]
  describe 'delete_location_postgres_metric_destination test' do
    it 'should work' do
      # assertion here. ref: https://rspec.info/features/3-12/rspec-expectations/built-in-matchers/
    end
  end

end
