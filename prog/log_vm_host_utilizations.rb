# frozen_string_literal: true

class Prog::LogVmHostUtilizations < Prog::Base
  label def wait
    rows = VmHost.where { (total_cores > 0) & (total_hugepages_1g > 0) }.select {
      [
        :allocation_state, :location_id, :arch, :family,
        count(:id).as(:host_count),
        sum(:used_cores).as(:used_cores),
        sum(:total_cores).as(:total_cores),
        round(sum(:used_cores) * 100.0 / sum(:total_cores), 2).cast(:float).as(:core_utilization),
        sum(:used_hugepages_1g).as(:used_hugepages_1g),
        sum(:total_hugepages_1g).as(:total_hugepages_1g),
        round(sum(:used_hugepages_1g) * 100.0 / sum(:total_hugepages_1g), 2).cast(:float).as(:hugepage_utilization),
        sum(floor((Sequel[:total_cores] - Sequel[:used_cores]) / Sequel.case({"x64" => 1, "arm64" => 2}, 0, :arch))).cast(:integer).as(:available_standard_2_count),
        sum(floor((Sequel[:total_cores] - Sequel[:used_cores]) / Sequel.case({"x64" => 2, "arm64" => 4}, 0, :arch))).cast(:integer).as(:available_standard_4_count),
        sum(floor((Sequel[:total_cores] - Sequel[:used_cores]) / Sequel.case({"x64" => 4, "arm64" => 8}, 0, :arch))).cast(:integer).as(:available_standard_8_count),
        sum(floor((Sequel[:total_cores] - Sequel[:used_cores]) / Sequel.case({"x64" => 8, "arm64" => 16}, 0, :arch))).cast(:integer).as(:available_standard_16_count),
        sum(floor((Sequel[:total_cores] - Sequel[:used_cores]) / Sequel.case({"x64" => 15, "arm64" => 30}, 0, :arch))).cast(:integer).as(:available_standard_30_count),
        sum(floor((Sequel[:total_cores] - Sequel[:used_cores]) / Sequel.case({"x64" => 30, "arm64" => 60}, 0, :arch))).cast(:integer).as(:available_standard_60_count)
      ]
    }.group(:allocation_state, :location_id, :arch, :family).all

    rows.each { |row| Clog.emit("location utilization") { {location_utilization: row.values} } }

    aggregation_keys = [:host_count, :used_cores, :total_cores, :used_hugepages_1g, :total_hugepages_1g,
      :available_standard_2_count, :available_standard_4_count, :available_standard_8_count, :available_standard_16_count,
      :available_standard_30_count, :available_standard_60_count].freeze

    rows.select { |row| row[:allocation_state] == "accepting" }.group_by { [it[:arch], it[:family]] }.each do |(arch, family), rows|
      values = rows.each_with_object(Hash.new(0)) do |row, totals|
        aggregation_keys.each { totals[it] += row[it] }
      end
      values[:arch] = arch
      values[:family] = family
      values[:core_utilization] = (values[:used_cores] * 100.0 / values[:total_cores]).round(2)
      values[:hugepage_utilization] = (values[:used_hugepages_1g] * 100.0 / values[:total_hugepages_1g]).round(2)
      Clog.emit("arch utilization") { {arch_utilization: values} }
    end

    nap 60
  end
end
