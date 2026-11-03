# frozen_string_literal: true

require "excon"
require "json"

module EcbExchangeRate
  URL = "https://data-api.ecb.europa.eu/service/data/EXR/D.USD.EUR.SP00.A?lastNObservations=1&format=jsondata"

  # The ECB publishes USD per 1 EUR, but invoices use EUR per 1 USD.
  def self.usd_to_eur
    data = JSON.parse(Excon.get(URL, expects: 200, connect_timeout: 5, read_timeout: 5).body)
    usd_per_eur = data["dataSets"][0]["series"].values.first["observations"].values.first.first
    (1 / usd_per_eur).round(6)
  rescue Excon::Error => e
    Clog.emit("Could not fetch ECB exchange rate", {could_not_fetch_ecb_exchange_rate: {error: e.message}})
    nil
  end
end
