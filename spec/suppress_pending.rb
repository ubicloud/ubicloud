# frozen_string_literal: true

# When running specs with frozen core, Database, or models, do not show
# all skipped tests after the run. This is the approach recommended by
# rspec maintainers in
# https://github.com/rspec/rspec-core/issues/2377#issuecomment-275131981
module FormatterOverrides
  def dump_pending(_)
  end
end

RSpec::Core::Formatters::DocumentationFormatter.prepend FormatterOverrides
RSpec::Core::Formatters::ProgressFormatter.prepend FormatterOverrides
