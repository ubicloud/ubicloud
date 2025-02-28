# frozen_string_literal: true

class Prog::LogVmHostUtilizations < Prog::Base
  label def wait
    rows = VmHost.where { (total_cores > 0) & (total_hugepages_1g > 0) }.select {
      [
        :allocation_state, :location_id, :arch,
        count(:id).as(:host_count),
        sum(:used_cores).as(:used_cores),
        sum(:total_cores).as(:total_cores),
        round((sum(:used_cores) * 100.0 / sum(:total_cores)), 2).cast(:float).as(:core_utilization),
        sum(:used_hugepages_1g).as(:used_hugepages_1g),
        sum(:total_hugepages_1g).as(:total_hugepages_1g),
        round((sum(:used_hugepages_1g) * 100.0 / sum(:total_hugepages_1g)), 2).cast(:float).as(:hugepage_utilization)
      ]
    }.group(:allocation_state, :location_id, :arch).all

    rows.each { |row| Clog.emit("location utilization") { {location_utilization: row.values} } }

    rows.select { |row| row[:allocation_state] == "accepting" }.group_by(&:arch).each do |arch, arch_rows|
      values = arch_rows.each_with_object(Hash.new(0)) do |row, totals|
        totals[:host_count] += row[:host_count]
        totals[:used_cores] += row[:used_cores]
        totals[:total_cores] += row[:total_cores]
        totals[:used_hugepages_1g] += row[:used_hugepages_1g]
        totals[:total_hugepages_1g] += row[:total_hugepages_1g]
      end
      values[:arch] = arch
      values[:core_utilization] = (values[:used_cores] * 100.0 / values[:total_cores]).round(2)
      values[:hugepage_utilization] = (values[:used_hugepages_1g] * 100.0 / values[:total_hugepages_1g]).round(2)

      Clog.emit("arch utilization") { {arch_utilization: values} }
    end

    nap 60
  end
end
