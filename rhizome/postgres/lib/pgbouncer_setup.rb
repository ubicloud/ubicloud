# frozen_string_literal: true

class PgBouncerSetup
  def initialize(version, max_connections, num_instances, user_config)
    @version = version
    @max_connections = max_connections
    @num_instances = num_instances
    @user_config = user_config
  end

  def service_template_name
    "pgbouncer@"
  end

  def pgbouncer_service_file_path
    "/etc/systemd/system/#{service_template_name}.service"
  end

  def socket_service_file_path
    "/etc/systemd/system/#{service_template_name}.socket"
  end

  def create_service_templates
    File.write(pgbouncer_service_file_path, <<PGBOUNCER_SERVICE
[Unit]
Description="connection pooler for PostgreSQL (%i)"
After=network.target
Requires=pgbouncer@%i.socket

[Service]
Type=notify
User=postgres
ExecStart=/usr/sbin/pgbouncer /etc/pgbouncer/pgbouncer_%i.ini
ExecReload=/bin/kill -HUP $MAINPID
KillSignal=SIGINT

[Install]
WantedBy=multi-user.target
PGBOUNCER_SERVICE
    )

    File.write(socket_service_file_path, <<PGBOUNCER_SOCKET
[Unit]
Description=Sockets for PgBouncer

[Socket]
ListenStream=6432
ListenStream=%i
ListenStream=/tmp/.s.PGSQL.%i

ReusePort=true

[Install]
WantedBy=sockets.target
PGBOUNCER_SOCKET
    )

    r "systemctl daemon-reload"
  end

  def port_num(id)
    50000 + id
  end

  def peer_config
    peers = (1..@num_instances.to_i).map do |i|
      "#{i} = host=/tmp/.s.PGSQL.#{port_num(i)}"
    end.join("\n")

    <<PGBOUNCER_PEER
[peers]
#{peers}
PGBOUNCER_PEER
  end

  def create_pgbouncer_config
    (1..@num_instances.to_i).each do |i|
      File.write("/etc/pgbouncer/pgbouncer_#{port_num(i)}.ini", <<PGBOUNCER_CONFIG
# PgBouncer configuration file
# ============================
[databases]
; any db over Unix socket
* =

[pgbouncer]
listen_port = 6432
listen_addr = 0.0.0.0

unix_socket_dir = /var/run/postgresql
so_reuseport = 1
peer_id = #{i}

auth_type = hba
auth_hba_file = /etc/postgresql/#{@version}/main/pg_hba.conf
auth_ident_file = /etc/postgresql/#{@version}/main/pg_ident.conf
auth_user = pgbouncer
auth_query = SELECT p_user, p_password FROM pgbouncer.get_auth($1)

client_tls_sslmode = require
client_tls_protocols = tlsv1.3
client_tls_ca_file = /etc/ssl/certs/ca.crt
client_tls_cert_file = /etc/ssl/certs/server.crt
client_tls_key_file = /etc/ssl/certs/server.key

user = postgres

max_client_conn = #{5000 / @num_instances.to_i}
max_db_connections = #{@max_connections.to_i / @num_instances.to_i}

#{@user_config.map { |k, v| "#{k} = #{v}" }.join("\n")}

; Peer configuration, to correctly forward cancellation requests.
#{peer_config}
PGBOUNCER_CONFIG
      )
    end
  end

  def disable_default_pgbouncer
    r "systemctl disable --now pgbouncer"
  end

  def enable_and_start_service
    (1..@num_instances.to_i).each do |i|
      r "systemctl reload #{service_template_name}#{port_num(i)} || systemctl enable --now #{service_template_name}#{port_num(i)}"
    end
  end

  def setup
    create_service_templates
    create_pgbouncer_config
    disable_default_pgbouncer
    enable_and_start_service
  end
end
