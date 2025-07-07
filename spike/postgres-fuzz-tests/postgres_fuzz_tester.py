#!/usr/bin/env python3
"""
PostgreSQL Fuzz Testing Framework for Ubicloud
Comprehensive testing tool for PostgreSQL database operations, high availability, and data integrity.
"""

import json
import yaml
import time
import random
import string
import hashlib
import logging
import argparse
import threading
from datetime import datetime, timedelta
from typing import Dict, List, Any, Optional, Tuple
from dataclasses import dataclass, asdict
from concurrent.futures import ThreadPoolExecutor, as_completed

import requests
import psycopg2
from psycopg2.extras import RealDictCursor
import urllib3

# Disable SSL warnings for local testing
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('postgres_fuzz_test.log'),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

@dataclass
class TestConfig:
    """Configuration for the test environment"""
    base_url: str
    bearer_token: str
    project_id: str
    location: str
    verify_ssl: bool = False

@dataclass
class DatabaseConfig:
    """Configuration for database creation"""
    name: str
    size: str = "standard-2"
    storage_size: int = 64
    ha_type: str = "none"
    version: str = "17"
    flavor: str = "standard"

@dataclass
class TestResult:
    """Result of a test step"""
    step_name: str
    success: bool
    duration: float
    message: str
    data: Optional[Dict] = None
    error: Optional[str] = None

@dataclass
class TestScenarioResult:
    """Result of an entire test scenario"""
    scenario_name: str
    start_time: datetime
    end_time: datetime
    total_duration: float
    success: bool
    steps: List[TestResult]
    summary: Dict[str, Any]

class UbicloudAPIClient:
    """Client for interacting with Ubicloud API"""
    
    def __init__(self, config: TestConfig):
        self.config = config
        self.session = requests.Session()
        self.session.headers.update({
            'Authorization': f'Bearer {config.bearer_token}',
            'Content-Type': 'application/json'
        })
    
    def _make_request(self, method: str, endpoint: str, **kwargs) -> requests.Response:
        """Make HTTP request to Ubicloud API"""
        url = f"{self.config.base_url}{endpoint}"
        kwargs.setdefault('verify', self.config.verify_ssl)
        
        logger.debug(f"{method} {url}")
        response = self.session.request(method, url, **kwargs)
        
        if response.status_code >= 400:
            logger.error(f"API Error: {response.status_code} - {response.text}")
        
        return response
    
    def create_postgres_database(self, db_config: DatabaseConfig) -> Dict:
        """Create a PostgreSQL database"""
        endpoint = f"/project/{self.config.project_id}/location/{self.config.location}/postgres/{db_config.name}"
        
        payload = {
            "size": db_config.size,
            "storage_size": db_config.storage_size,
            "ha_type": db_config.ha_type,
            "version": db_config.version,
            "flavor": db_config.flavor
        }
        
        response = self._make_request('POST', endpoint, json=payload)
        response.raise_for_status()
        return response.json()
    
    def get_postgres_database(self, db_name: str) -> Dict:
        """Get PostgreSQL database details"""
        endpoint = f"/project/{self.config.project_id}/location/{self.config.location}/postgres/{db_name}"
        response = self._make_request('GET', endpoint)
        response.raise_for_status()
        return response.json()
    
    def delete_postgres_database(self, db_name: str) -> bool:
        """Delete PostgreSQL database"""
        endpoint = f"/project/{self.config.project_id}/location/{self.config.location}/postgres/{db_name}"
        response = self._make_request('DELETE', endpoint)
        return response.status_code == 204
    
    def create_read_replica(self, primary_db_name: str, replica_name: str) -> Dict:
        """Create a read replica"""
        endpoint = f"/project/{self.config.project_id}/location/{self.config.location}/postgres/{primary_db_name}/read-replica"
        payload = {"name": replica_name}
        response = self._make_request('POST', endpoint, json=payload)
        response.raise_for_status()
        return response.json()
    
    def promote_read_replica(self, replica_name: str) -> Dict:
        """Promote read replica to primary"""
        endpoint = f"/project/{self.config.project_id}/location/{self.config.location}/postgres/{replica_name}/promote"
        response = self._make_request('POST', endpoint)
        response.raise_for_status()
        return response.json()
    
    def restart_database(self, db_name: str) -> Dict:
        """Restart PostgreSQL database"""
        endpoint = f"/project/{self.config.project_id}/location/{self.config.location}/postgres/{db_name}/restart"
        response = self._make_request('POST', endpoint)
        response.raise_for_status()
        return response.json()
    
    def create_firewall_rule(self, db_name: str, cidr: str, description: str = None) -> Dict:
        """Create firewall rule for database"""
        endpoint = f"/project/{self.config.project_id}/location/{self.config.location}/postgres/{db_name}/firewall-rule"
        payload = {"cidr": cidr}
        if description:
            payload["description"] = description
        response = self._make_request('POST', endpoint, json=payload)
        response.raise_for_status()
        return response.json()
    
    def get_database_metrics(self, db_name: str, start_time: str = None, end_time: str = None) -> Dict:
        """Get database metrics"""
        endpoint = f"/project/{self.config.project_id}/location/{self.config.location}/postgres/{db_name}/metrics"
        params = {}
        if start_time:
            params['start'] = start_time
        if end_time:
            params['end'] = end_time
        
        response = self._make_request('GET', endpoint, params=params)
        response.raise_for_status()
        return response.json()
    
    def patch_postgres_database(self, db_name: str, **kwargs) -> Dict:
        """Update PostgreSQL database configuration"""
        endpoint = f"/project/{self.config.project_id}/location/{self.config.location}/postgres/{db_name}"
        
        # Filter out None values
        payload = {k: v for k, v in kwargs.items() if v is not None}
        
        response = self._make_request('PATCH', endpoint, json=payload)
        response.raise_for_status()
        return response.json()
    
    def set_maintenance_window(self, db_name: str, maintenance_window_start_at: int) -> Dict:
        """Set maintenance window for database"""
        endpoint = f"/project/{self.config.project_id}/location/{self.config.location}/postgres/{db_name}/set-maintenance-window"
        payload = {"maintenance_window_start_at": maintenance_window_start_at}
        response = self._make_request('POST', endpoint, json=payload)
        response.raise_for_status()
        return response.json()
    
    def reset_superuser_password(self, db_name: str, password: str) -> Dict:
        """Reset superuser password"""
        endpoint = f"/project/{self.config.project_id}/location/{self.config.location}/postgres/{db_name}/reset-superuser-password"
        payload = {"password": password}
        response = self._make_request('POST', endpoint, json=payload)
        response.raise_for_status()
        return response.json()
    
    def restore_postgres_database(self, source_db_name: str, new_db_name: str, restore_target: str) -> Dict:
        """Restore database from backup"""
        endpoint = f"/project/{self.config.project_id}/location/{self.config.location}/postgres/{source_db_name}/restore"
        payload = {
            "name": new_db_name,
            "restore_target": restore_target
        }
        response = self._make_request('POST', endpoint, json=payload)
        response.raise_for_status()
        return response.json()
    
    def get_database_config(self, db_name: str) -> Dict:
        """Get database configuration"""
        endpoint = f"/project/{self.config.project_id}/location/{self.config.location}/postgres/{db_name}/config"
        response = self._make_request('GET', endpoint)
        response.raise_for_status()
        return response.json()
    
    def update_database_config(self, db_name: str, pg_config: Dict = None, pgbouncer_config: Dict = None) -> Dict:
        """Update database configuration"""
        endpoint = f"/project/{self.config.project_id}/location/{self.config.location}/postgres/{db_name}/config"
        payload = {}
        if pg_config:
            payload['pg_config'] = pg_config
        if pgbouncer_config:
            payload['pgbouncer_config'] = pgbouncer_config
        
        response = self._make_request('POST', endpoint, json=payload)
        response.raise_for_status()
        return response.json()

class PostgreSQLClient:
    """Client for direct PostgreSQL database operations"""
    
    def __init__(self, connection_string: str):
        self.connection_string = connection_string
        self.connection = None
    
    def connect(self) -> bool:
        """Establish database connection"""
        try:
            self.connection = psycopg2.connect(
                self.connection_string,
                cursor_factory=RealDictCursor,
                connect_timeout=30
            )
            self.connection.autocommit = True
            return True
        except Exception as e:
            logger.error(f"Failed to connect to database: {e}")
            return False
    
    def disconnect(self):
        """Close database connection"""
        if self.connection:
            self.connection.close()
            self.connection = None
    
    def execute_query(self, query: str, params: tuple = None) -> List[Dict]:
        """Execute SQL query and return results"""
        if not self.connection:
            raise Exception("Not connected to database")
        
        with self.connection.cursor() as cursor:
            cursor.execute(query, params)
            if cursor.description:
                return [dict(row) for row in cursor.fetchall()]
            return []
    
    def create_test_table(self, table_name: str, columns: Dict[str, str]) -> bool:
        """Create a test table"""
        try:
            column_defs = ", ".join([f"{name} {dtype}" for name, dtype in columns.items()])
            query = f"CREATE TABLE IF NOT EXISTS {table_name} ({column_defs})"
            self.execute_query(query)
            return True
        except Exception as e:
            logger.error(f"Failed to create table {table_name}: {e}")
            return False
    
    def insert_test_data(self, table_name: str, data: List[Dict]) -> bool:
        """Insert test data into table"""
        try:
            if not data:
                return True
            
            columns = list(data[0].keys())
            placeholders = ", ".join(["%s"] * len(columns))
            query = f"INSERT INTO {table_name} ({', '.join(columns)}) VALUES ({placeholders})"
            
            with self.connection.cursor() as cursor:
                for row in data:
                    cursor.execute(query, [row[col] for col in columns])
            return True
        except Exception as e:
            logger.error(f"Failed to insert data into {table_name}: {e}")
            return False
    
    def get_table_count(self, table_name: str) -> int:
        """Get row count for table"""
        try:
            result = self.execute_query(f"SELECT COUNT(*) as count FROM {table_name}")
            return result[0]['count'] if result else 0
        except Exception as e:
            logger.error(f"Failed to get count for {table_name}: {e}")
            return -1
    
    def get_table_checksum(self, table_name: str) -> str:
        """Calculate checksum for table data"""
        try:
            query = f"SELECT md5(string_agg(md5(t.*::text), '' ORDER BY md5(t.*::text))) as checksum FROM {table_name} t"
            result = self.execute_query(query)
            return result[0]['checksum'] if result else ""
        except Exception as e:
            logger.error(f"Failed to calculate checksum for {table_name}: {e}")
            return ""
    
    def check_replication_status(self) -> Dict:
        """Check replication status"""
        try:
            # Check if this is a primary or standby
            result = self.execute_query("SELECT pg_is_in_recovery() as is_standby")
            is_standby = result[0]['is_standby'] if result else False
            
            if is_standby:
                # Get standby status
                result = self.execute_query("""
                    SELECT 
                        pg_last_wal_receive_lsn() as receive_lsn,
                        pg_last_wal_replay_lsn() as replay_lsn,
                        EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp())) as lag_seconds
                """)
                return {"role": "standby", "status": result[0] if result else {}}
            else:
                # Get primary status
                result = self.execute_query("""
                    SELECT 
                        client_addr,
                        state,
                        sent_lsn,
                        write_lsn,
                        flush_lsn,
                        replay_lsn,
                        sync_state
                    FROM pg_stat_replication
                """)
                return {"role": "primary", "replicas": result}
        except Exception as e:
            logger.error(f"Failed to check replication status: {e}")
            return {"error": str(e)}

class PostgresFuzzTester:
    """Main fuzz testing orchestrator"""
    
    def __init__(self, config: TestConfig):
        self.config = config
        self.api_client = UbicloudAPIClient(config)
        self.test_results: List[TestScenarioResult] = []
        self.created_databases: List[str] = []
    
    def generate_random_string(self, length: int = 8) -> str:
        """Generate random string for test data"""
        return ''.join(random.choices(string.ascii_lowercase + string.digits, k=length))
    
    def generate_test_data(self, num_rows: int) -> List[Dict]:
        """Generate test data for insertion"""
        data = []
        for i in range(num_rows):
            data.append({
                'id': i + 1,
                'name': f"test_user_{self.generate_random_string(6)}",
                'email': f"user{i}@example.com",
                'created_at': datetime.now(),
                'data_hash': hashlib.md5(f"test_data_{i}".encode()).hexdigest()
            })
        return data
    
    def wait_for_database_ready(self, db_name: str, timeout: int = 600) -> bool:
        """Wait for database to be in running state"""
        start_time = time.time()
        while time.time() - start_time < timeout:
            try:
                db_info = self.api_client.get_postgres_database(db_name)
                state = db_info.get('state', 'unknown')
                logger.info(f"Database {db_name} state: {state}")
                
                if state == 'running':
                    return True
                elif state in ['deleting', 'unavailable']:
                    return False
                
                time.sleep(10)
            except Exception as e:
                logger.warning(f"Error checking database status: {e}")
                time.sleep(10)
        
        return False
    
    def run_test_step(self, step_name: str, test_func, *args, **kwargs) -> TestResult:
        """Execute a single test step and measure performance"""
        start_time = time.time()
        try:
            logger.info(f"Executing step: {step_name}")
            result = test_func(*args, **kwargs)
            duration = time.time() - start_time
            
            if isinstance(result, tuple):
                success, message, data = result
            elif isinstance(result, bool):
                success, message, data = result, "Success" if result else "Failed", None
            else:
                success, message, data = True, "Success", result
            
            return TestResult(
                step_name=step_name,
                success=success,
                duration=duration,
                message=message,
                data=data
            )
        except Exception as e:
            duration = time.time() - start_time
            logger.error(f"Step {step_name} failed: {e}")
            return TestResult(
                step_name=step_name,
                success=False,
                duration=duration,
                message="Exception occurred",
                error=str(e)
            )
    
    def test_create_database(self, db_config: DatabaseConfig) -> Tuple[bool, str, Dict]:
        """Test database creation"""
        try:
            result = self.api_client.create_postgres_database(db_config)
            self.created_databases.append(db_config.name)
            
            # Wait for database to be ready
            if self.wait_for_database_ready(db_config.name):
                return True, f"Database {db_config.name} created successfully", result
            else:
                return False, f"Database {db_config.name} failed to become ready", result
        except Exception as e:
            return False, f"Failed to create database: {e}", None
    
    def test_database_connection(self, db_name: str) -> Tuple[bool, str, Dict]:
        """Test database connectivity"""
        try:
            db_info = self.api_client.get_postgres_database(db_name)
            connection_string = db_info.get('connection_string')
            
            if not connection_string:
                return False, "No connection string available", None
            
            client = PostgreSQLClient(connection_string)
            if client.connect():
                # Test basic query
                result = client.execute_query("SELECT version(), current_database(), current_user")
                client.disconnect()
                return True, "Database connection successful", {"query_result": result}
            else:
                return False, "Failed to connect to database", None
        except Exception as e:
            return False, f"Connection test failed: {e}", None
    
    def test_data_operations(self, db_name: str, table_count: int = 3, rows_per_table: int = 100) -> Tuple[bool, str, Dict]:
        """Test basic data operations"""
        try:
            db_info = self.api_client.get_postgres_database(db_name)
            connection_string = db_info.get('connection_string')
            
            client = PostgreSQLClient(connection_string)
            if not client.connect():
                return False, "Failed to connect to database", None
            
            results = {}
            
            # Create tables and insert data
            for i in range(table_count):
                table_name = f"test_table_{i}"
                
                # Create table
                columns = {
                    'id': 'SERIAL PRIMARY KEY',
                    'name': 'VARCHAR(100)',
                    'email': 'VARCHAR(100)',
                    'created_at': 'TIMESTAMP',
                    'data_hash': 'VARCHAR(32)'
                }
                
                if not client.create_test_table(table_name, columns):
                    client.disconnect()
                    return False, f"Failed to create table {table_name}", None
                
                # Insert test data
                test_data = self.generate_test_data(rows_per_table)
                if not client.insert_test_data(table_name, test_data):
                    client.disconnect()
                    return False, f"Failed to insert data into {table_name}", None
                
                # Verify data
                count = client.get_table_count(table_name)
                checksum = client.get_table_checksum(table_name)
                
                results[table_name] = {
                    'expected_rows': rows_per_table,
                    'actual_rows': count,
                    'checksum': checksum
                }
            
            client.disconnect()
            
            # Verify all operations succeeded
            success = all(r['actual_rows'] == r['expected_rows'] for r in results.values())
            message = "Data operations completed successfully" if success else "Data verification failed"
            
            return success, message, results
        except Exception as e:
            return False, f"Data operations failed: {e}", None
    
    def test_replication_validation(self, primary_db_name: str) -> Tuple[bool, str, Dict]:
        """Test replication functionality"""
        try:
            # Get primary database info
            primary_info = self.api_client.get_postgres_database(primary_db_name)
            primary_connection = primary_info.get('connection_string')
            
            if not primary_connection:
                return False, "Primary database connection string not available", None
            
            # Connect to primary
            primary_client = PostgreSQLClient(primary_connection)
            if not primary_client.connect():
                return False, "Failed to connect to primary database", None
            
            # Check replication status
            replication_status = primary_client.check_replication_status()
            primary_client.disconnect()
            
            return True, "Replication validation completed", replication_status
        except Exception as e:
            return False, f"Replication validation failed: {e}", None
    
    def test_read_replica_creation(self, primary_db_name: str) -> Tuple[bool, str, Dict]:
        """Test read replica creation and validation"""
        replica_name = f"{primary_db_name}-replica-{self.generate_random_string(4)}"
        
        try:
            # Create read replica
            result = self.api_client.create_read_replica(primary_db_name, replica_name)
            self.created_databases.append(replica_name)
            
            # Wait for replica to be ready
            if not self.wait_for_database_ready(replica_name):
                return False, f"Read replica {replica_name} failed to become ready", None
            
            # Validate replica
            replica_info = self.api_client.get_postgres_database(replica_name)
            replica_connection = replica_info.get('connection_string')
            
            if replica_connection:
                replica_client = PostgreSQLClient(replica_connection)
                if replica_client.connect():
                    replication_status = replica_client.check_replication_status()
                    replica_client.disconnect()
                    
                    return True, f"Read replica {replica_name} created and validated", {
                        "replica_name": replica_name,
                        "replication_status": replication_status
                    }
            
            return False, "Failed to validate read replica", None
        except Exception as e:
            return False, f"Read replica creation failed: {e}", None
    
    def test_failover_scenario(self, primary_db_name: str) -> Tuple[bool, str, Dict]:
        """Test database failover scenario"""
        try:
            # First create a read replica
            replica_result = self.test_read_replica_creation(primary_db_name)
            if not replica_result[0]:
                return False, "Failed to create replica for failover test", None
            
            replica_name = replica_result[2]['replica_name']
            
            # Insert some data before failover
            data_result = self.test_data_operations(primary_db_name, table_count=1, rows_per_table=50)
            if not data_result[0]:
                return False, "Failed to insert pre-failover data", None
            
            pre_failover_checksum = list(data_result[2].values())[0]['checksum']
            
            # Promote replica to primary
            promote_result = self.api_client.promote_read_replica(replica_name)
            
            # Wait for promotion to complete
            time.sleep(30)
            
            # Validate new primary
            new_primary_info = self.api_client.get_postgres_database(replica_name)
            new_connection = new_primary_info.get('connection_string')
            
            if new_connection:
                client = PostgreSQLClient(new_connection)
                if client.connect():
                    # Check data integrity
                    post_failover_checksum = client.get_table_checksum('test_table_0')
                    client.disconnect()
                    
                    data_integrity = pre_failover_checksum == post_failover_checksum
                    
                    return True, "Failover scenario completed", {
                        "promoted_replica": replica_name,
                        "data_integrity_preserved": data_integrity,
                        "pre_failover_checksum": pre_failover_checksum,
                        "post_failover_checksum": post_failover_checksum
                    }
            
            return False, "Failed to validate failover", None
        except Exception as e:
            return False, f"Failover scenario failed: {e}", None
    
    def test_performance_metrics(self, db_name: str) -> Tuple[bool, str, Dict]:
        """Test performance metrics collection"""
        try:
            # Get current metrics with RFC3339 format
            end_time = datetime.now()
            start_time = end_time - timedelta(minutes=30)
            
            # Format timestamps in RFC3339 format as expected by the API
            start_str = start_time.strftime('%Y-%m-%dT%H:%M:%S+00:00')
            end_str = end_time.strftime('%Y-%m-%dT%H:%M:%S+00:00')
            
            metrics = self.api_client.get_database_metrics(
                db_name,
                start_str,
                end_str
            )
            
            return True, "Performance metrics collected", metrics
        except Exception as e:
            return False, f"Failed to collect metrics: {e}", None
    
    def test_scale_up(self, db_name: str, new_size: str = None, new_storage_size: int = None) -> Tuple[bool, str, Dict]:
        """Test scaling up database resources"""
        try:
            # Get current database info
            current_info = self.api_client.get_postgres_database(db_name)
            current_size = current_info.get('vm_size')
            current_storage = current_info.get('storage_size_gib')
            
            # Determine new values if not provided
            if not new_size:
                size_map = {'standard-2': 'standard-4', 'standard-4': 'standard-8'}
                new_size = size_map.get(current_size, 'standard-4')
            
            if not new_storage_size:
                new_storage_size = min(current_storage * 2, 256)  # Cap at 256GB
            
            # Perform scaling
            result = self.api_client.patch_postgres_database(
                db_name,
                size=new_size,
                storage_size=new_storage_size
            )
            
            # Wait for scaling to complete
            if self.wait_for_database_ready(db_name, timeout=900):  # 15 minutes for scaling
                updated_info = self.api_client.get_postgres_database(db_name)
                return True, f"Database scaled from {current_size}/{current_storage}GB to {new_size}/{new_storage_size}GB", {
                    "previous": {"size": current_size, "storage": current_storage},
                    "new": {"size": updated_info.get('vm_size'), "storage": updated_info.get('storage_size_gib')},
                    "scaling_result": result
                }
            else:
                return False, "Database failed to complete scaling operation", None
                
        except Exception as e:
            return False, f"Scale up failed: {e}", None
    
    def test_scale_down(self, db_name: str, new_size: str = None) -> Tuple[bool, str, Dict]:
        """Test scaling down database resources (size only, storage cannot be reduced)"""
        try:
            # Get current database info
            current_info = self.api_client.get_postgres_database(db_name)
            current_size = current_info.get('vm_size')
            
            # Determine new size if not provided
            if not new_size:
                size_map = {'standard-8': 'standard-4', 'standard-4': 'standard-2'}
                new_size = size_map.get(current_size, 'standard-2')
            
            # Perform scaling
            result = self.api_client.patch_postgres_database(db_name, size=new_size)
            
            # Wait for scaling to complete
            if self.wait_for_database_ready(db_name, timeout=900):
                updated_info = self.api_client.get_postgres_database(db_name)
                return True, f"Database scaled down from {current_size} to {new_size}", {
                    "previous_size": current_size,
                    "new_size": updated_info.get('vm_size'),
                    "scaling_result": result
                }
            else:
                return False, "Database failed to complete scaling operation", None
                
        except Exception as e:
            return False, f"Scale down failed: {e}", None
    
    def test_change_ha_type(self, db_name: str, new_ha_type: str) -> Tuple[bool, str, Dict]:
        """Test changing high availability type"""
        try:
            # Get current database info
            current_info = self.api_client.get_postgres_database(db_name)
            current_ha_type = current_info.get('ha_type')
            
            if current_ha_type == new_ha_type:
                return True, f"Database already has HA type {new_ha_type}", {"ha_type": current_ha_type}
            
            # Change HA type
            result = self.api_client.patch_postgres_database(db_name, ha_type=new_ha_type)
            
            # Wait for change to complete
            if self.wait_for_database_ready(db_name, timeout=1200):  # 20 minutes for HA changes
                updated_info = self.api_client.get_postgres_database(db_name)
                return True, f"HA type changed from {current_ha_type} to {new_ha_type}", {
                    "previous_ha_type": current_ha_type,
                    "new_ha_type": updated_info.get('ha_type'),
                    "change_result": result
                }
            else:
                return False, "Database failed to complete HA type change", None
                
        except Exception as e:
            return False, f"HA type change failed: {e}", None
    
    def test_set_maintenance_window(self, db_name: str, maintenance_hour: int = None) -> Tuple[bool, str, Dict]:
        """Test setting maintenance window"""
        try:
            # Use provided hour or random hour between 2-6 AM
            if maintenance_hour is None:
                maintenance_hour = random.randint(2, 6)
            
            result = self.api_client.set_maintenance_window(db_name, maintenance_hour)
            
            # Verify the setting
            updated_info = self.api_client.get_postgres_database(db_name)
            actual_window = updated_info.get('maintenance_window_start_at')
            
            return True, f"Maintenance window set to hour {maintenance_hour}", {
                "requested_hour": maintenance_hour,
                "actual_window": actual_window,
                "result": result
            }
            
        except Exception as e:
            return False, f"Setting maintenance window failed: {e}", None
    
    def test_restart_database(self, db_name: str) -> Tuple[bool, str, Dict]:
        """Test database restart"""
        try:
            # Get pre-restart info
            pre_restart_info = self.api_client.get_postgres_database(db_name)
            
            # Restart database
            result = self.api_client.restart_database(db_name)
            
            # Wait for restart to complete
            if self.wait_for_database_ready(db_name, timeout=600):
                post_restart_info = self.api_client.get_postgres_database(db_name)
                return True, "Database restarted successfully", {
                    "restart_result": result,
                    "pre_restart_state": pre_restart_info.get('state'),
                    "post_restart_state": post_restart_info.get('state')
                }
            else:
                return False, "Database failed to restart properly", None
                
        except Exception as e:
            return False, f"Database restart failed: {e}", None
    
    def test_password_reset(self, db_name: str) -> Tuple[bool, str, Dict]:
        """Test superuser password reset"""
        try:
            # Generate new password
            new_password = f"TestPass{self.generate_random_string(12)}!"
            
            result = self.api_client.reset_superuser_password(db_name, new_password)
            
            # Test connection with new password
            db_info = self.api_client.get_postgres_database(db_name)
            connection_string = db_info.get('connection_string')
            
            if connection_string:
                # Replace password in connection string for testing
                import re
                new_connection_string = re.sub(
                    r'password=[^&\s]+',
                    f'password={new_password}',
                    connection_string
                )
                
                client = PostgreSQLClient(new_connection_string)
                if client.connect():
                    client.disconnect()
                    return True, "Password reset and validated successfully", {
                        "password_reset_result": result,
                        "connection_test": "successful"
                    }
                else:
                    return False, "Password reset but connection test failed", None
            else:
                return True, "Password reset completed", {"password_reset_result": result}
                
        except Exception as e:
            return False, f"Password reset failed: {e}", None
    
    def test_firewall_rules(self, db_name: str) -> Tuple[bool, str, Dict]:
        """Test firewall rule management"""
        try:
            results = {}
            
            # Create test firewall rules
            test_rules = [
                {"cidr": "10.0.0.0/8", "description": "Private network access"},
                {"cidr": "192.168.1.0/24", "description": "Local subnet access"},
                {"cidr": "172.16.0.0/12", "description": "Docker network access"}
            ]
            
            created_rules = []
            for rule in test_rules:
                try:
                    rule_result = self.api_client.create_firewall_rule(
                        db_name,
                        rule["cidr"],
                        rule["description"]
                    )
                    created_rules.append(rule_result)
                    results[f"rule_{rule['cidr']}"] = "created"
                except Exception as e:
                    results[f"rule_{rule['cidr']}"] = f"failed: {e}"
            
            return True, f"Firewall rules test completed, {len(created_rules)} rules created", {
                "created_rules": created_rules,
                "results": results
            }
            
        except Exception as e:
            return False, f"Firewall rules test failed: {e}", None
    
    def test_database_config_update(self, db_name: str) -> Tuple[bool, str, Dict]:
        """Test database configuration updates"""
        try:
            # Get current config
            current_config = self.api_client.get_database_config(db_name)
            
            # Test configuration changes
            test_pg_config = {
                "max_connections": "150",
                "shared_buffers": "256MB",
                "effective_cache_size": "1GB"
            }
            
            test_pgbouncer_config = {
                "max_client_conn": "200",
                "default_pool_size": "25"
            }
            
            # Update configuration
            update_result = self.api_client.update_database_config(
                db_name,
                pg_config=test_pg_config,
                pgbouncer_config=test_pgbouncer_config
            )
            
            # Verify changes
            updated_config = self.api_client.get_database_config(db_name)
            
            return True, "Database configuration updated successfully", {
                "previous_config": current_config,
                "update_result": update_result,
                "new_config": updated_config
            }
            
        except Exception as e:
            return False, f"Database config update failed: {e}", None
    
    def test_backup_restore(self, source_db_name: str) -> Tuple[bool, str, Dict]:
        """Test database backup and restore functionality"""
        try:
            # Create some test data first
            data_result = self.test_data_operations(source_db_name, table_count=2, rows_per_table=25)
            if not data_result[0]:
                return False, "Failed to create test data for backup", None
            
            # Get source data checksums
            source_checksums = {k: v['checksum'] for k, v in data_result[2].items()}
            
            # Create restore target name
            restore_db_name = f"{source_db_name}-restore-{self.generate_random_string(4)}"
            
            # Use current time as restore target (latest backup)
            restore_target = datetime.now().strftime('%Y-%m-%dT%H:%M:%S+00:00')
            
            # Perform restore
            restore_result = self.api_client.restore_postgres_database(
                source_db_name,
                restore_db_name,
                restore_target
            )
            
            self.created_databases.append(restore_db_name)
            
            # Wait for restore to complete
            if not self.wait_for_database_ready(restore_db_name, timeout=1200):
                return False, "Restored database failed to become ready", None
            
            # Validate restored data
            restored_info = self.api_client.get_postgres_database(restore_db_name)
            restored_connection = restored_info.get('connection_string')
            
            if restored_connection:
                client = PostgreSQLClient(restored_connection)
                if client.connect():
                    restored_checksums = {}
                    for table_name in source_checksums.keys():
                        restored_checksums[table_name] = client.get_table_checksum(table_name)
                    client.disconnect()
                    
                    # Compare checksums
                    data_integrity = source_checksums == restored_checksums
                    
                    return True, f"Database restored successfully as {restore_db_name}", {
                        "restore_result": restore_result,
                        "restored_db_name": restore_db_name,
                        "data_integrity_preserved": data_integrity,
                        "source_checksums": source_checksums,
                        "restored_checksums": restored_checksums
                    }
            
            return False, "Failed to validate restored database", None
            
        except Exception as e:
            return False, f"Backup/restore test failed: {e}", None
    
    def test_stress_operations(self, db_name: str, duration_minutes: int = 5) -> Tuple[bool, str, Dict]:
        """Test database under stress conditions"""
        try:
            db_info = self.api_client.get_postgres_database(db_name)
            connection_string = db_info.get('connection_string')
            
            if not connection_string:
                return False, "No connection string available", None
            
            results = {
                "operations_completed": 0,
                "errors": 0,
                "average_response_time": 0,
                "peak_connections": 0
            }
            
            start_time = time.time()
            end_time = start_time + (duration_minutes * 60)
            response_times = []
            
            while time.time() < end_time:
                operation_start = time.time()
                try:
                    client = PostgreSQLClient(connection_string)
                    if client.connect():
                        # Perform random operations
                        operation_type = random.choice(['select', 'insert', 'update'])
                        
                        if operation_type == 'select':
                            client.execute_query("SELECT COUNT(*) FROM pg_stat_activity")
                        elif operation_type == 'insert':
                            test_data = self.generate_test_data(1)
                            client.execute_query(
                                "INSERT INTO test_table_0 (name, email, created_at, data_hash) VALUES (%s, %s, %s, %s)",
                                (test_data[0]['name'], test_data[0]['email'], test_data[0]['created_at'], test_data[0]['data_hash'])
                            )
                        elif operation_type == 'update':
                            client.execute_query(
                                "UPDATE test_table_0 SET name = %s WHERE id = %s",
                                (f"updated_{self.generate_random_string(4)}", random.randint(1, 100))
                            )
                        
                        client.disconnect()
                        results["operations_completed"] += 1
                        
                except Exception as e:
                    results["errors"] += 1
                    logger.debug(f"Stress test operation failed: {e}")
                
                operation_time = time.time() - operation_start
                response_times.append(operation_time)
                
                # Brief pause between operations
                time.sleep(0.1)
            
            if response_times:
                results["average_response_time"] = sum(response_times) / len(response_times)
            
            success = results["operations_completed"] > 0 and results["errors"] < results["operations_completed"] * 0.1
            message = f"Stress test completed: {results['operations_completed']} operations, {results['errors']} errors"
            
            return success, message, results
            
        except Exception as e:
            return False, f"Stress test failed: {e}", None
    
    def cleanup_databases(self):
        """Clean up created databases"""
        for db_name in self.created_databases:
            try:
                logger.info(f"Cleaning up database: {db_name}")
                self.api_client.delete_postgres_database(db_name)
                time.sleep(5)  # Brief pause between deletions
            except Exception as e:
                logger.error(f"Failed to cleanup database {db_name}: {e}")
        
        self.created_databases.clear()
    
    def run_scenario(self, scenario: Dict) -> TestScenarioResult:
        """Run a complete test scenario"""
        scenario_name = scenario.get('name', 'Unknown Scenario')
        start_time = datetime.now()
        
        logger.info(f"Starting test scenario: {scenario_name}")
        
        steps = []
        scenario_success = True
        
        try:
            for step in scenario.get('steps', []):
                action = step.get('action')
                params = step.get('params', {})
                
                if action == 'create_database':
                    db_config = DatabaseConfig(
                        name=f"fuzz-test-{self.generate_random_string(8)}",
                        **params
                    )
                    result = self.run_test_step(
                        f"create_database_{db_config.name}",
                        self.test_create_database,
                        db_config
                    )
                    # Store database name for subsequent steps
                    if result.success:
                        scenario['_primary_db'] = db_config.name
                
                elif action == 'validate_connection':
                    db_name = scenario.get('_primary_db')
                    if db_name:
                        result = self.run_test_step(
                            'validate_connection',
                            self.test_database_connection,
                            db_name
                        )
                    else:
                        result = TestResult('validate_connection', False, 0, 'No database available')
                
                elif action == 'write_data':
                    db_name = scenario.get('_primary_db')
                    if db_name:
                        result = self.run_test_step(
                            'write_data',
                            self.test_data_operations,
                            db_name,
                            params.get('table_count', 3),
                            params.get('rows_per_table', 100)
                        )
                    else:
                        result = TestResult('write_data', False, 0, 'No database available')
                
                elif action == 'validate_replication':
                    db_name = scenario.get('_primary_db')
                    if db_name:
                        result = self.run_test_step(
                            'validate_replication',
                            self.test_replication_validation,
                            db_name
                        )
                    else:
                        result = TestResult('validate_replication', False, 0, 'No database available')
                
                elif action == 'create_read_replica':
                    db_name = scenario.get('_primary_db')
                    if db_name:
                        result = self.run_test_step(
                            'create_read_replica',
                            self.test_read_replica_creation,
                            db_name
                        )
                    else:
                        result = TestResult('create_read_replica', False, 0, 'No database available')
                
                elif action == 'test_failover':
                    db_name = scenario.get('_primary_db')
                    if db_name:
                        result = self.run_test_step(
                            'test_failover',
                            self.test_failover_scenario,
                            db_name
                        )
                    else:
                        result = TestResult('test_failover', False, 0, 'No database available')
                
                elif action == 'collect_metrics':
                    db_name = scenario.get('_primary_db')
                    if db_name:
                        result = self.run_test_step(
                            'collect_metrics',
                            self.test_performance_metrics,
                            db_name
                        )
                    else:
                        result = TestResult('collect_metrics', False, 0, 'No database available')
                
                elif action == 'scale_up':
                    db_name = scenario.get('_primary_db')
                    if db_name:
                        result = self.run_test_step(
                            'scale_up',
                            self.test_scale_up,
                            db_name,
                            params.get('new_size'),
                            params.get('new_storage_size')
                        )
                    else:
                        result = TestResult('scale_up', False, 0, 'No database available')
                
                elif action == 'scale_down':
                    db_name = scenario.get('_primary_db')
                    if db_name:
                        result = self.run_test_step(
                            'scale_down',
                            self.test_scale_down,
                            db_name,
                            params.get('new_size')
                        )
                    else:
                        result = TestResult('scale_down', False, 0, 'No database available')
                
                elif action == 'change_ha_type':
                    db_name = scenario.get('_primary_db')
                    if db_name:
                        result = self.run_test_step(
                            'change_ha_type',
                            self.test_change_ha_type,
                            db_name,
                            params.get('new_ha_type', 'async')
                        )
                    else:
                        result = TestResult('change_ha_type', False, 0, 'No database available')
                
                elif action == 'set_maintenance_window':
                    db_name = scenario.get('_primary_db')
                    if db_name:
                        result = self.run_test_step(
                            'set_maintenance_window',
                            self.test_set_maintenance_window,
                            db_name,
                            params.get('maintenance_hour')
                        )
                    else:
                        result = TestResult('set_maintenance_window', False, 0, 'No database available')
                
                elif action == 'restart_database':
                    db_name = scenario.get('_primary_db')
                    if db_name:
                        result = self.run_test_step(
                            'restart_database',
                            self.test_restart_database,
                            db_name
                        )
                    else:
                        result = TestResult('restart_database', False, 0, 'No database available')
                
                elif action == 'reset_password':
                    db_name = scenario.get('_primary_db')
                    if db_name:
                        result = self.run_test_step(
                            'reset_password',
                            self.test_password_reset,
                            db_name
                        )
                    else:
                        result = TestResult('reset_password', False, 0, 'No database available')
                
                elif action == 'test_firewall_rules':
                    db_name = scenario.get('_primary_db')
                    if db_name:
                        result = self.run_test_step(
                            'test_firewall_rules',
                            self.test_firewall_rules,
                            db_name
                        )
                    else:
                        result = TestResult('test_firewall_rules', False, 0, 'No database available')
                
                elif action == 'update_config':
                    db_name = scenario.get('_primary_db')
                    if db_name:
                        result = self.run_test_step(
                            'update_config',
                            self.test_database_config_update,
                            db_name
                        )
                    else:
                        result = TestResult('update_config', False, 0, 'No database available')
                
                elif action == 'test_backup_restore':
                    db_name = scenario.get('_primary_db')
                    if db_name:
                        result = self.run_test_step(
                            'test_backup_restore',
                            self.test_backup_restore,
                            db_name
                        )
                    else:
                        result = TestResult('test_backup_restore', False, 0, 'No database available')
                
                elif action == 'stress_test':
                    db_name = scenario.get('_primary_db')
                    if db_name:
                        result = self.run_test_step(
                            'stress_test',
                            self.test_stress_operations,
                            db_name,
                            params.get('duration_minutes', 5)
                        )
                    else:
                        result = TestResult('stress_test', False, 0, 'No database available')
                
                elif action == 'cleanup':
                    result = self.run_test_step(
                        'cleanup',
                        lambda: (True, "Cleanup initiated", None)
                    )
                    self.cleanup_databases()
                
                else:
                    result = TestResult(action, False, 0, f'Unknown action: {action}')
                
                steps.append(result)
                if not result.success:
                    scenario_success = False
                    logger.warning(f"Step {action} failed: {result.message}")
        
        except Exception as e:
            logger.error(f"Scenario {scenario_name} failed with exception: {e}")
            scenario_success = False
            steps.append(TestResult('scenario_exception', False, 0, str(e)))
        
        end_time = datetime.now()
        total_duration = (end_time - start_time).total_seconds()
        
        # Generate summary
        summary = {
            'total_steps': len(steps),
            'successful_steps': sum(1 for s in steps if s.success),
            'failed_steps': sum(1 for s in steps if not s.success),
            'average_step_duration': sum(s.duration for s in steps) / len(steps) if steps else 0,
            'databases_created': len(self.created_databases)
        }
        
        result = TestScenarioResult(
            scenario_name=scenario_name,
            start_time=start_time,
            end_time=end_time,
            total_duration=total_duration,
            success=scenario_success,
            steps=steps,
            summary=summary
        )
        
        self.test_results.append(result)
        return result
    
    def generate_report(self, output_file: str = None):
        """Generate comprehensive test report"""
        report = {
            'test_run_summary': {
                'timestamp': datetime.now().isoformat(),
                'total_scenarios': len(self.test_results),
                'successful_scenarios': sum(1 for r in self.test_results if r.success),
                'failed_scenarios': sum(1 for r in self.test_results if not r.success),
                'total_duration': sum(r.total_duration for r in self.test_results)
            },
            'scenarios': []
        }
        
        for result in self.test_results:
            scenario_report = {
                'name': result.scenario_name,
                'success': result.success,
                'duration': result.total_duration,
                'summary': result.summary,
                'steps': [
                    {
                        'name': step.step_name,
                        'success': step.success,
                        'duration': step.duration,
                        'message': step.message,
                        'error': step.error
                    }
                    for step in result.steps
                ]
            }
            report['scenarios'].append(scenario_report)
        
        if output_file:
            with open(output_file, 'w') as f:
                json.dump(report, f, indent=2, default=str)
            logger.info(f"Test report saved to {output_file}")
        
        return report

def load_test_scenarios(file_path: str) -> List[Dict]:
    """Load test scenarios from YAML file"""
    with open(file_path, 'r') as f:
        if file_path.endswith('.yaml') or file_path.endswith('.yml'):
            data = yaml.safe_load(f)
        else:
            data = json.load(f)
    
    return data.get('scenarios', [])

def load_config_from_file(file_path: str) -> TestConfig:
    """Load configuration from credentials file"""
    config = {}
    with open(file_path, 'r') as f:
        for line in f:
            line = line.strip()
            if line and '=' in line:
                key, value = line.split('=', 1)
                config[key] = value
    
    return TestConfig(
        base_url=config['BASE_URL'],
        bearer_token=config['BEARER_AUTH_TOKEN'],
        project_id=config['TEST_PROJECT'],
        location=config['TEST_LOCATION']
    )

def main():
    """Main entry point for the fuzz tester"""
    parser = argparse.ArgumentParser(description='PostgreSQL Fuzz Testing Framework for Ubicloud')
    parser.add_argument('--config', '-c', required=True, help='Path to configuration file')
    parser.add_argument('--scenarios', '-s', required=True, help='Path to test scenarios file')
    parser.add_argument('--output', '-o', help='Output file for test report')
    parser.add_argument('--parallel', '-p', type=int, default=1, help='Number of parallel test scenarios')
    parser.add_argument('--verbose', '-v', action='store_true', help='Enable verbose logging')
    
    args = parser.parse_args()
    
    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)
    
    try:
        # Load configuration
        config = load_config_from_file(args.config)
        logger.info(f"Loaded configuration from {args.config}")
        
        # Load test scenarios
        scenarios = load_test_scenarios(args.scenarios)
        logger.info(f"Loaded {len(scenarios)} test scenarios from {args.scenarios}")
        
        # Initialize tester
        tester = PostgresFuzzTester(config)
        
        # Run scenarios
        if args.parallel > 1:
            logger.info(f"Running scenarios in parallel with {args.parallel} workers")
            with ThreadPoolExecutor(max_workers=args.parallel) as executor:
                futures = [executor.submit(tester.run_scenario, scenario) for scenario in scenarios]
                for future in as_completed(futures):
                    result = future.result()
                    logger.info(f"Scenario '{result.scenario_name}' completed: {'SUCCESS' if result.success else 'FAILED'}")
        else:
            logger.info("Running scenarios sequentially")
            for scenario in scenarios:
                result = tester.run_scenario(scenario)
                logger.info(f"Scenario '{result.scenario_name}' completed: {'SUCCESS' if result.success else 'FAILED'}")
        
        # Generate report
        output_file = args.output or f"postgres_fuzz_test_report_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
        report = tester.generate_report(output_file)
        
        # Print summary
        summary = report['test_run_summary']
        logger.info("=" * 60)
        logger.info("TEST RUN SUMMARY")
        logger.info("=" * 60)
        logger.info(f"Total Scenarios: {summary['total_scenarios']}")
        logger.info(f"Successful: {summary['successful_scenarios']}")
        logger.info(f"Failed: {summary['failed_scenarios']}")
        logger.info(f"Total Duration: {summary['total_duration']:.2f} seconds")
        logger.info(f"Report saved to: {output_file}")
        
        # Cleanup any remaining databases
        tester.cleanup_databases()
        
        # Exit with appropriate code
        exit_code = 0 if summary['failed_scenarios'] == 0 else 1
        exit(exit_code)
        
    except Exception as e:
        logger.error(f"Fatal error: {e}")
        exit(1)

if __name__ == "__main__":
    main()
