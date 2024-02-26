# frozen_string_literal: true

Sequel.migration do
  up do
    run "TRUNCATE billing_rate CASCADE"
    copy_into :billing_rate, data: <<COPY
139d9a67-8182-8578-a303-235cabd5161c	VmCores	standard	hetzner-fsn1	0.000171296
08c502f7-df5d-8978-9896-feafa0ec5c40	VmCores	standard	hetzner-hel1	0.000154167
COPY
  end
end
