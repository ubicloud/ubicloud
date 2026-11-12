# frozen_string_literal: true

require_relative "../../model"

class DnsZone < Sequel::Model
  one_to_one :strand, key: :id, read_only: true
  many_to_one :project, read_only: true
  many_to_many :dns_servers, remover: nil, clearer: nil, is_used: true
  one_to_many :records, class: :DnsRecord, remover: nil, clearer: nil

  plugin ResourceMethods
  plugin SemaphoreMethods, :refresh_dns_servers

  # Values are interpolated into knotc commands, so the patterns also keep
  # whitespace and other knotc syntax out.
  APEX_HOSTNAME = /\A(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.?\z/i
  APEX_EMAIL = /\A[a-z0-9_+-]+(?:\.[a-z0-9_+-]+)*@(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/i

  def validate
    super
    if nameservers
      errors.add(:nameservers, "must not be empty") if nameservers.empty?
      errors.add(:nameservers, "must be hostnames") unless nameservers.all? { it.match?(APEX_HOSTNAME) }
    end
    errors.add(:soa_email, "must be an email address") if soa_email && !soa_email.match?(APEX_EMAIL)
  end

  def update_apex(nameservers:, soa_email:)
    set(nameservers:, soa_email:)
    return unless modified? || revert_apex

    self.revert_apex = !custom_apex?
    save_changes
    Clog.emit("DNS zone apex changed", {dns_zone_apex: {ubid:, name:, nameservers:, soa_email:, revert_apex:}})
    dns_servers.each(&:incr_configure)
  end

  def custom_apex?
    !nameservers.nil? || !soa_email.nil?
  end

  # revert_apex marks a zone whose configured values were removed: its VMs
  # may still serve them until the defaults are written back.
  def manages_apex?
    custom_apex? || revert_apex
  end

  def apex_nameservers(dns_server)
    (nameservers || [dns_server.name]).map { add_dot_if_missing(it.downcase) }
  end

  def soa_mname
    nameservers ? add_dot_if_missing(nameservers.first.downcase) : "ns.#{name}."
  end

  # RFC 1035 RNAME: the mailbox with "@" turned into a label separator, and
  # dots inside the local part escaped.
  def soa_rname
    return "#{name}." unless soa_email

    local, domain = soa_email.downcase.split("@", 2)
    "#{local.gsub(".") { "\\." }}.#{domain}."
  end

  def apex_commands(dns_server, zone_read)
    current_ns = []
    soa = nil
    zone_read.each_line do |line|
      fields = line.split
      # Older knotc prefixes each record with "[zone.]" even for a single zone.
      fields.shift if fields.first == "[#{name}.]"
      owner, _ttl, type, *rdata = fields
      next unless owner == "#{name}."

      current_ns << rdata.first if type == "NS"
      soa = rdata if type == "SOA"
    end
    fail "Zone #{name} has no SOA record" unless soa

    desired_ns = apex_nameservers(dns_server)
    commands = (current_ns - desired_ns).map { "zone-unset #{name} @ NS #{it}" }
    commands.concat((desired_ns - current_ns).map { "zone-set #{name} @ 3600 NS #{it}" })

    mname, rname, serial, *timers = soa
    unless mname == soa_mname && rname == soa_rname
      # knot rejects an SOA whose serial does not increase, and its knotc
      # parser consumes one level of backslash escaping.
      commands << "zone-set #{name} @ 3600 SOA #{soa_mname} #{soa_rname.gsub("\\") { "\\\\" }} #{Integer(serial, 10) + 1} #{timers.join(" ")}"
    end

    commands
  end

  def rectify_apex(dns_server, vm)
    return unless manages_apex?

    sshable = vm.sshable
    current = sshable.cmd("sudo -u knot knotc", stdin: "zone-read #{name} @ NS\nzone-read #{name} @ SOA", log: false)
    changes = apex_commands(dns_server, current)
    return if changes.empty?

    commands = ["zone-abort #{name}", "zone-begin #{name}", *changes, "zone-commit #{name}"]
    Clog.emit("Updating DNS zone apex", {dns_zone: name, vm_ubid: vm.ubid, commands:})
    sshable.cmd("sudo -u knot knotc", stdin: commands.join("\n")).split("\n").each_with_index do |output, index|
      next if output == "OK"
      next if index == 0 && output.include?("no active transaction")

      fail "Updating apex of #{name} failed on #{vm.ubid}. Command: #{commands[index]}. Output: #{output}"
    end
  end

  def insert_record(record_name:, type:, ttl:, data:)
    record_name = add_dot_if_missing(record_name)
    add_record(name: record_name, type:, ttl:, data:)

    incr_refresh_dns_servers
  end

  def delete_record(record_name:, type: nil, data: nil)
    fail "Type needs to be specified if data is specified!" if data && type.nil?

    record_name = add_dot_if_missing(record_name)
    records = records_dataset.where(name: record_name, tombstoned: false)
    records = records.where(type:) if type
    records = records.where(data:) if data

    DB[:dns_record].import(
      [:id, :dns_zone_id, :name, :type, :ttl, :data, :tombstoned],
      records.distinct.select_map([:name, :type, :ttl, :data]).map do
        [DnsRecord.generate_uuid, id, *it, true]
      end,
    )

    incr_refresh_dns_servers
  end

  def purge_obsolete_records
    DB.transaction do
      # These are the records that are obsoleted by a another record with the
      # same fields but newer date. We can delete them even if they are not
      # seen yet.
      obsoleted_records = records_dataset
        .join(
          records_dataset
            .select_group(:dns_zone_id, :name, :type, :data)
            .select_append { max(created_at).as(:latest_created_at) }
            .as(:latest_dns_record),
          [:dns_zone_id, :name, :type, :data],
        )
        .where { dns_record[:created_at] < latest_dns_record[:latest_created_at] }.all

      # These are the tombstoned records, we can only delete them if they are
      # seen by all DNS servers. We join with seen_dns_records_by_dns_servers
      # and count the number of DNS servers to ensure that they are seen by all
      # DNS servers.
      dns_server_ids = dns_servers.map(&:id)
      seen_tombstoned_records = records_dataset
        .select_group(:id)
        .join(:seen_dns_records_by_dns_servers, dns_record_id: :id, dns_server_id: dns_server_ids)
        .where(tombstoned: true)
        .having { count.function.* =~ dns_server_ids.count }.all

      records_to_purge = obsoleted_records + seen_tombstoned_records
      records_to_purge.uniq!(&:id)
      DB[:seen_dns_records_by_dns_servers].where(dns_record_id: records_to_purge.map(&:id)).delete
      records_to_purge.each(&:destroy)

      this.update(last_purged_at: Sequel::CURRENT_TIMESTAMP)
    end
  end

  def add_dot_if_missing(record_name)
    (record_name[-1] == ".") ? record_name : record_name + "."
  end
end

# Table: dns_zone
# Columns:
#  id             | uuid                     | PRIMARY KEY
#  created_at     | timestamp with time zone | NOT NULL DEFAULT now()
#  project_id     | uuid                     | NOT NULL
#  name           | text                     | NOT NULL
#  last_purged_at | timestamp with time zone | NOT NULL DEFAULT now()
#  neg_ttl        | integer                  | NOT NULL DEFAULT 3600
#  nameservers    | text[]                   |
#  soa_email      | text                     |
#  revert_apex    | boolean                  | NOT NULL DEFAULT false
# Indexes:
#  dns_zone_pkey                 | PRIMARY KEY btree (id)
#  dns_zone_project_id_name_uidx | UNIQUE btree (project_id, name)
# Foreign key constraints:
#  dns_zone_project_id_fkey | (project_id) REFERENCES project(id)
# Referenced By:
#  cert                  | cert_dns_zone_id_fkey                          | (dns_zone_id) REFERENCES dns_zone(id)
#  dns_record            | dns_record_dns_zone_id_fkey                    | (dns_zone_id) REFERENCES dns_zone(id)
#  dns_servers_dns_zones | dns_servers_dns_zones_dns_zone_id_fkey         | (dns_zone_id) REFERENCES dns_zone(id)
#  load_balancer         | load_balancer_custom_hostname_dns_zone_id_fkey | (custom_hostname_dns_zone_id) REFERENCES dns_zone(id)
