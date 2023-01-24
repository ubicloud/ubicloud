# frozen_string_literal: true

require "sequel"
DB
Model = Sequel::Model
Sequel::Model.plugin :singular_table_names
