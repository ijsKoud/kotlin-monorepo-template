#!/usr/bin/env bash
# Points a service's image in the gitops checkout at a new version.
#
# usage: gitops-set-image.sh <gitops-checkout> <service-dir> <image-name> <image-with-digest> <new-version> <rollback>
#   service-dir  the service's directory inside the checkout, e.g. apps/my-project/hello
#   rollback     "true" allows going back to an older version
#
# Fails when the service's manifests are missing.
# Writes needs_deploy=true|false to $GITHUB_OUTPUT: false means gitops already holds a newer version.
set -euo pipefail

gitops_checkout=$1
service_dir=$2
image_name=$3
image_with_digest=$4
new_version=$5
rollback=$6

manifests_dir="$gitops_checkout/$service_dir"

# Succeeds when version $1 is higher than version $2.
is_newer() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]
}

if [ ! -d "$manifests_dir" ]; then
  echo "::error::$service_dir does not exist in homelab-gitops; add the manifests before releasing this service"
  exit 1
fi

# The manifest files with an "image: <image-name>:<tag>" or "image: <image-name>@<digest>" line.
manifest_files=$(grep -rlE "image: *${image_name}[:@]" "$manifests_dir" --include='*.yaml' --include='*.yml' || true)
if [ -z "$manifest_files" ]; then
  echo "::error::no 'image: $image_name' line found under $service_dir"
  exit 1
fi

# The version gitops runs now (empty when the image line has no x.y.z tag).
current_version=$(grep -rhoE "image: *${image_name}:[0-9]+\.[0-9]+\.[0-9]+" $manifest_files | head -1 | sed -E 's/.*:([0-9.]+)$/\1/' || true)

if [ -n "$current_version" ] && [ "$rollback" != "true" ] && is_newer "$current_version" "$new_version"; then
  echo "::notice::gitops already has $current_version, which is newer than $new_version; skipping (use the rollback option to go back)"
  echo "needs_deploy=false" >> "$GITHUB_OUTPUT"
  exit 0
fi

# Replace everything after "image: " (tag and digest) with the new reference.
# shellcheck disable=SC2086 # the file list is intentionally split into separate arguments
sed -i.bak -E "s|(image: *)${image_name}[:@][^[:space:]]*|\1${image_with_digest}|" $manifest_files
find "$manifests_dir" -name '*.bak' -delete
echo "needs_deploy=true" >> "$GITHUB_OUTPUT"
