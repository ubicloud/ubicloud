# frozen_string_literal: true

require "countries"

class Serializers::InvoiceV2 < Serializers::InvoiceV1
  InvoiceData = Data.define(*Serializers::InvoiceV1::InvoiceData.members, :discounts, :credits)
  BreakdownData = Data.define(:name, :amount)

  def self.hash_for(inv, options)
    hash = super
    %i[credits discounts].each do |k|
      hash[k] = inv.content[k.to_s].map { |d| BreakdownData.new(name: d["name"], amount: "$%0.02f" % d["amount"]) }
    end
    hash
  end
end
