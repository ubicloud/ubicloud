#!/usr/bin/env bash

set -euo pipefail

function log {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" >&2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAPPING_FILE="$SCRIPT_DIR/runner-mapping.yml"
PREFIX="ch-internal-ubimirror-"
TARGET_BRANCH="${TARGET_BRANCH:-clickhouse}"

# Check if yq is available
if ! command -v yq &> /dev/null; then
  log "ERROR: yq is not installed. Please install it first."
  exit 1
fi

log "Removing old CI files"
rm -v ./.github/workflows/"${PREFIX}"*.yml || true

rsync --no-motd --out-format="%n" --dry-run -Iu --backup -az -f'P .git/***'  -f'H .git/***' --delete-excluded --exclude-from ./.github/scripts/mirror-ci.exclude  --include-from ./.github/scripts/mirror-ci.include --include '*/' --exclude '*' . "$1" --prune-empty-dirs | while IFS= read -r file; do
  filename=$(basename "$file")
  parent_dir=$(dirname "$file")
  new_file="$parent_dir/$PREFIX$filename"

  log "Processing: $file -> $new_file"
  cp "$file" "$new_file"
  
  # Apply runner replacements from mapping file using yq
  yq eval '.mappings | to_entries | sort_by(.key | length) | reverse | .[]' "$MAPPING_FILE" | while read -r entry; do
    ubicloud_runner=$(echo "$entry" | yq eval '.key' -)
    k8s_runner=$(echo "$entry" | yq eval '.value' -)
    
    # Use yq to replace runs-on values in the YAML file
    yq eval -i "(.. | select(has(\"runs-on\")) | .runs-on | select(. == \"$ubicloud_runner\")) = \"$k8s_runner\"" "$new_file"
    
    # Also handle matrix arrays
    yq eval -i "(.. | select(has(\"runs-on\")) | .runs-on | select(type == \"!!seq\") | .[] | select(. == \"$ubicloud_runner\")) = \"$k8s_runner\"" "$new_file"
  done
  
  # Post-processing: deduplicate runners in matrix arrays
  log "Deduplicating runners in $new_file"
  yq eval -i '(.. | select(has("runs-on")) | .runs-on | select(type == "!!seq")) |= unique' "$new_file"
  
  # Replace branch references with TARGET_BRANCH
  log "Replacing branch references with $TARGET_BRANCH in $new_file"
  yq eval -i "
    (.. | select(has(\"ref\")) | .ref | select(. == \"main\" or . == \"master\")) = \"$TARGET_BRANCH\" |
    (.. | select(has(\"branch\")) | .branch | select(. == \"main\" or . == \"master\")) = \"$TARGET_BRANCH\" |
    (.. | select(has(\"branches\")) | .branches | select(type == \"!!seq\") | .[] | select(. == \"main\" or . == \"master\")) = \"$TARGET_BRANCH\"
  " "$new_file"
  
  # Add env block at top level if it doesn't exist
  log "Adding env block to $new_file"
  if ! yq eval 'has("env")' "$new_file" | grep -q "true"; then
    yq eval -i '.env = {"LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"}' "$new_file"
  else
    yq eval -i '.env.LANG = "en_US.UTF-8" | .env.LC_ALL = "en_US.UTF-8"' "$new_file"
  fi
  
  # Prefix workflow name with [INTERNAL]
  log "Adding [INTERNAL] prefix to workflow name in $new_file"
  yq eval -i '.name = "[INTERNAL] " + .name' "$new_file"
  
  # Add tool cache directory setup step before ruby/setup-ruby steps
  log "Adding tool cache setup before ruby setup actions in $new_file"
  for job in $(yq eval '.jobs | keys | .[]' "$new_file"); do
    step_count=$(yq eval ".jobs.$job.steps | length" "$new_file")
    for ((i=step_count-1; i>=0; i--)); do
      uses=$(yq eval ".jobs.$job.steps[$i].uses // \"\"" "$new_file")
      if [[ "$uses" == *"ruby/setup-ruby"* ]]; then
        yq eval -i ".jobs.$job.steps |= (.[0:$i] + [{\"name\": \"Setup tool cache directory\", \"shell\": \"bash\", \"run\": \"sudo mkdir -p /opt/hostedtoolcache && sudo chown -R \\\"\$(whoami)\\\":\\\"\$(whoami)\\\" /opt/hostedtoolcache\n\"}] + .[$i:])" "$new_file"
      fi
    done
  done
  
  log "Applied runner replacements to $new_file"
done

log "Done!"
