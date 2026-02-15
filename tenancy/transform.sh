#!/usr/bin/env bash

# transform.sh - Convert discovery JSON to provision JSON

# Input: discovery.json (pure capture)
# Output: provision.json (ready to execute)

set -euo pipefail

transform() {
  local discovery="$1"
  local provision="$2"

  # 1. Filter resources (apply include/exclude rules)
  # 2. Generate logical keys (comp:path, vcn:path/name)
  # 3. Resolve dependencies (build graph)
  # 4. Apply transformations (rename, remap tags)
  # 5. Sort by dependency order (phases)
  # 6. Remove discovery metadata (OCIDs, timestamps)
  # 7. Add provisioning metadata (dependencies, validations)
}