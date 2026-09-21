#!/usr/bin/env bash

# SwiftPM and Xcode's SwiftPM backend place modules in different locations.
swift_module_search_path() {
  local bin_path="$1"
  local module_name="$2"
  local candidate
  for candidate in "$bin_path/Modules" "$bin_path"; do
    if [[ -e "$candidate/$module_name.swiftmodule" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  printf 'Cannot find %s.swiftmodule in %s/Modules or %s\n' \
    "$module_name" "$bin_path" "$bin_path" >&2
  return 1
}
