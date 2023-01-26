# frozen_string_literal: true

require "sequel"
Model = Sequel::Model
Model.db = DB
Sequel::Model.plugin :singular_table_names
