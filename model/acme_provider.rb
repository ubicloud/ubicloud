# frozen_string_literal: true

require_relative "../model"
require "acme-client"
require "json"
require "uri"

# A certificate authority reachable over ACME. The rows are derived from
# configuration by reconcile_from_config!, which an operator runs from a
# console; see the comment there.
class AcmeProvider < Sequel::Model
  one_to_one :acme_account
  one_to_many :certs

  plugin ResourceMethods, etc_type: true, encrypted_columns: [:eab_hmac_key]

  # The keys an ACME_PROVIDERS entry may have, each with a check of its
  # JSON value and a description of what the check expects.
  STRING = [->(value) { value.is_a?(String) }, "a string"].freeze
  INTEGER = [->(value) { value.is_a?(Integer) }, "an integer"].freeze
  BOOLEAN = [->(value) { value == true || value == false }, "true or false"].freeze
  CONFIG_KEYS = {
    "directory" => STRING, "name" => STRING, "email" => STRING,
    "eab_kid" => STRING, "eab_hmac_key" => STRING,
    "per_cert_accounts" => BOOLEAN, "priority" => INTEGER, "enabled" => BOOLEAN,
    "evacuate" => BOOLEAN,
  }.freeze

  CLIENT_OPTIONS = {
    connection_options: {request: {open_timeout: 5, timeout: 10}.freeze}.freeze,
    bad_nonce_retry: 3,
  }.freeze

  # The provider rows are derived from ACME_PROVIDERS, or from the legacy
  # ACME_* variables when it is not set. reconcile_plan returns the
  # actions reconcile_from_config! would take; reconcile_from_config!
  # takes them and returns what it did. Configured providers are created
  # or updated, and the rest are disabled, never deleted. Entries marked
  # evacuate are evacuated; see evacuate!. Accounts and certificate pins
  # are not touched. Certificates issued before provider rows existed are
  # pinned separately, by backfill_legacy_cert_pins. Secret values never
  # appear in the returned actions.
  def self.reconcile_plan
    reconcile_actions.map { it[:describe] }
  end

  def self.reconcile_from_config!
    DB.transaction do
      # Recompute the actions with the rows locked, so that concurrent
      # runs serialize and the return value describes what this run
      # actually did, which may differ from an earlier reconcile_plan.
      actions = reconcile_actions(lock: true)
      actions.each { it[:apply].call }
      actions.map { it[:describe] }
    end
  end

  def self.reconcile_actions(lock: false)
    entries = if (json = Config.acme_providers)
      parse_config(json).each_with_index.map do |entry, index|
        directory_url = entry["directory"] || fail("ACME_PROVIDERS entries require a directory")
        evacuate = entry.fetch("evacuate", false)
        {directory_url:, name: entry["name"] || URI(directory_url).host,
         email: entry["email"], eab_kid: entry["eab_kid"], eab_hmac_key: entry["eab_hmac_key"],
         per_cert_accounts: entry.fetch("per_cert_accounts", false), priority: entry.fetch("priority", index),
         # An entry being evacuated stays disabled.
         enabled: evacuate ? false : entry.fetch("enabled", true), evacuate:}
      end
    else
      # The legacy variables describe a single provider. per_cert_accounts
      # keeps the old behavior of registering a new ACME account for each
      # certificate.
      [{directory_url: Config.acme_directory, name: URI(Config.acme_directory).host,
        email: Config.acme_email, eab_kid: Config.acme_eab_kid, eab_hmac_key: Config.acme_eab_hmac_key,
        per_cert_accounts: true, priority: 0, enabled: true, evacuate: false}]
    end
    fail "ACME_PROVIDERS must contain at least one provider" if entries.empty?

    actions = []
    rows = reconcile_snapshot(lock).to_h { [it.directory_url, it] }
    entries.each do |entry|
      entry = entry.dup
      evacuate = entry.delete(:evacuate)
      row = rows[entry[:directory_url]]
      evacuating = evacuate && (row.nil? || row.enabled || row.certs_dataset.exclude(cert: nil).where(reissue_requested_at: nil).count > 0)
      if row
        changes = entry.except(:directory_url).reject { |field, value| row.send(field) == value }
        # evacuate! disables the row; do not report that as an update too.
        changes.delete(:enabled) if evacuating
        unless changes.empty?
          actions << {describe: "update #{row.name} (#{changes.keys.join(", ")})",
                      apply: -> { row.update(**changes) }}
        end
      else
        actions << {describe: "create #{entry[:name]} #{entry[:directory_url]} (priority #{entry[:priority]})",
                    apply: lambda {
                      begin
                        # Without a savepoint, a unique violation would abort
                        # the enclosing transaction and the query below could
                        # not run.
                        DB.transaction(savepoint: true) { create(**entry) }
                      rescue Sequel::ValidationFailed, Sequel::UniqueConstraintViolation
                        # If a concurrent run created this directory first,
                        # update its row instead. Any other failure, such as
                        # a name already used by another directory, is a
                        # configuration error and must be raised.
                        winner = first(directory_url: entry[:directory_url])
                        raise unless winner
                        winner.update(**entry.except(:directory_url))
                      end
                    }}
      end
      if evacuating
        actions << {describe: "evacuate #{entry[:name]}",
                    apply: -> { first(directory_url: entry[:directory_url]).evacuate! }}
      end
    end

    configured = entries.map { it[:directory_url] }
    rows.each_value do |row|
      next if !row.enabled || configured.include?(row.directory_url)
      actions << {describe: "disable #{row.name}", apply: -> { row.update(enabled: false) }}
    end

    actions
  end
  private_class_method :reconcile_actions

  # Reject anything but an array of objects with known keys and values of
  # the right type. A value such as "false" would otherwise be stored as
  # false, but never compare equal to the row, so every plan would
  # propose the same update again.
  def self.parse_config(json)
    entries = JSON.parse(json)
    fail "ACME_PROVIDERS must be a JSON array" unless entries.is_a?(Array)
    entries.each do |entry|
      fail "ACME_PROVIDERS entries must be JSON objects" unless entry.is_a?(Hash)
      entry.each do |key, value|
        check, expected = CONFIG_KEYS[key] || fail("ACME_PROVIDERS entries take no #{key.inspect} key")
        fail "ACME_PROVIDERS key #{key.inspect} must be #{expected}" unless check.call(value)
      end
    end
  end
  private_class_method :parse_config

  def self.reconcile_snapshot(lock)
    snapshot = dataset.order(:priority, :name)
    snapshot = snapshot.for_update if lock
    snapshot.all
  end
  private_class_method :reconcile_snapshot

  # Summary of each provider and its certificates, for the console.
  def self.status
    order(:priority, :name).eager(:acme_account).all.map do |provider|
      issued = provider.certs_dataset.exclude(cert: nil)
      {name: provider.name, enabled: provider.enabled, priority: provider.priority,
       account_kid: provider.acme_account&.kid,
       issued_certs: issued.count,
       awaiting_reissue: issued.exclude(reissue_requested_at: nil).count}
    end
  end

  # Pin certificates issued before provider rows existed (those with an
  # embedded account key and no provider) to the provider for the legacy
  # directory, so they are still revoked at the CA that issued them.
  # Safe to rerun. Run it again once the issuance change is deployed, to
  # catch certificates the old code issued in the meantime, and remove it
  # once no unpinned certificates remain.
  def self.backfill_legacy_cert_pins
    provider = first(directory_url: Config.acme_directory) || fail("no provider row matches the legacy directory; run AcmeProvider.reconcile_from_config! first")
    count = Cert.where(acme_provider_id: nil).exclude(kid: nil).exclude(account_key: nil).update(acme_provider_id: provider.id)
    "pinned #{count} certificate#{"s" if count != 1}"
  end

  # Choose the provider for the given issuance attempt of a certificate.
  # Enabled providers are taken in priority order, rotated by the attempt
  # number, so that each restart moves to the next CA. A restart also
  # skips the provider the certificate last used, when there is another.
  def self.for_attempt(cert, attempt)
    candidates = where(enabled: true).order(:priority, :name).all
    fail "No enabled ACME provider is configured; run AcmeProvider.reconcile_from_config! from a console" if candidates.empty?
    chosen = candidates[attempt.to_i % candidates.size]
    if attempt.to_i > 0 && candidates.size > 1 && chosen.id == cert.acme_provider_id
      chosen = candidates[(attempt.to_i + 1) % candidates.size]
    end
    chosen
  end

  # Disable the provider and request early replacement of every
  # certificate it issued. The certificates leave Cert.fresh at once and
  # keep serving until their owners replace them through the normal
  # refresh. Destroying them skips revocation, as the provider is
  # disabled. Orders still in progress at this CA are restarted, so that
  # they move to another provider now rather than at an auto restart,
  # which not every certificate has.
  def evacuate!
    DB.transaction do
      update(enabled: false)
      certs_dataset.exclude(cert: nil).where(reissue_requested_at: nil).update(reissue_requested_at: Sequel::CURRENT_TIMESTAMP)
      ordering = Strand.where(prog: "Vnet::CertNexus", label: Prog::Vnet::CertNexus::ACME_ORDER_LABELS).select(:id)
      Cert.incr_restarted(certs_dataset.where(cert: nil, id: ordering).select(:id))
    end
  end

  # Returns [private_key, kid, embedded_account_key]. A shared-account
  # provider returns its one account and nothing to embed. A
  # per_cert_accounts provider registers a new account and returns its
  # key, to be stored on the certificate as before providers existed.
  def issuance_identity
    if per_cert_accounts
      private_key = OpenSSL::PKey::EC.generate("prime256v1")
      [private_key, register_account(private_key), private_key.to_der]
    else
      account = AcmeAccount.fetch_or_register(self)
      [account.private_key, account.kid, nil]
    end
  end

  def register_account(private_key)
    client = Acme::Client.new(private_key:, directory: directory_url, **CLIENT_OPTIONS)
    client.new_account(contact:, terms_of_service_agreed: true, external_account_binding:).kid
  end

  def contact
    "mailto:#{email}" if email
  end

  def external_account_binding
    {kid: eab_kid, hmac_key: eab_hmac_key} if eab_kid && eab_hmac_key
  end
end

# Table: acme_provider
# Columns:
#  id                | uuid                     | PRIMARY KEY
#  name              | text                     | NOT NULL
#  directory_url     | text                     | NOT NULL
#  email             | text                     |
#  eab_kid           | text                     |
#  eab_hmac_key      | text                     |
#  per_cert_accounts | boolean                  | NOT NULL DEFAULT false
#  priority          | integer                  | NOT NULL
#  enabled           | boolean                  | NOT NULL DEFAULT true
#  created_at        | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
# Indexes:
#  acme_provider_pkey              | PRIMARY KEY btree (id)
#  acme_provider_directory_url_key | UNIQUE btree (directory_url)
#  acme_provider_name_key          | UNIQUE btree (name)
# Referenced By:
#  acme_account | acme_account_acme_provider_id_fkey | (acme_provider_id) REFERENCES acme_provider(id)
#  cert         | cert_acme_provider_id_fkey         | (acme_provider_id) REFERENCES acme_provider(id)
