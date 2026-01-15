# frozen_string_literal: true

# This file is used to define the upgrade scripts for extensions.
# The key is the version and the value is a hash of extension name to upgrade
# script.
EXTENSION_UPGRADE_SCRIPTS = {
  17 => {
    "postgis" => "SELECT postgis_extensions_upgrade();"
  },
  18 => {
    "postgis" => "SELECT postgis_extensions_upgrade();"
  }
}
