#!/usr/bin/env bash
# Syncs an Argo CD application and waits until it is synced to the given revision and healthy.
#
# usage: argocd-sync-wait.sh <application> <revision>
# env:   ARGOCD_SERVER_URL, ARGOCD_TOKEN
#        optional, in seconds: APPEAR_TIMEOUT, APPEAR_INTERVAL, TIMEOUT, INTERVAL
set -euo pipefail

application=$1
expected_revision=$2

appear_timeout=${APPEAR_TIMEOUT:-300}   # how long a new application may take to be created
appear_interval=${APPEAR_INTERVAL:-10}
healthy_timeout=${TIMEOUT:-600}         # how long the rollout may take to become healthy
healthy_interval=${INTERVAL:-15}
healthy_checks_required=3               # consecutive good checks, so a short flicker does not count

application_url="$ARGOCD_SERVER_URL/api/v1/applications/$application"
response_file=/tmp/argocd-app.json

# Calls the Argo CD API and fails on any HTTP error.
argocd_api() { curl -fsS -H "Authorization: Bearer $ARGOCD_TOKEN" "$@"; }

# The ApplicationSet creates the application on its next git poll, so a new service may not exist yet.
# 404 and 403 both mean "not there yet": Argo CD answers 403 for a missing application unless the caller may read all of them.
# Any other status (401 bad token, wrong URL, ...) is a real error; a 403 that never turns into 200 is reported at the timeout.
wait_until_application_exists() {
  local waited=0 http_code
  while true; do
    http_code=$(curl -sS -o "$response_file" -w '%{http_code}' -H "Authorization: Bearer $ARGOCD_TOKEN" "$application_url")
    [ "$http_code" = 200 ] && return

    if [ "$http_code" != 404 ] && [ "$http_code" != 403 ]; then
      echo "::error::GET $application_url returned HTTP $http_code: $(head -c 300 "$response_file")"
      exit 1
    fi
    if [ "$waited" -ge "$appear_timeout" ]; then
      echo "::error::application $application did not become visible (last HTTP $http_code: $(head -c 300 "$response_file")). Either the ApplicationSet has not created it, or the token lacks 'applications, get' permission."
      exit 1
    fi

    echo "Application $application not visible yet (HTTP $http_code); waiting for the ApplicationSet..."
    sleep "$appear_interval"
    waited=$((waited + appear_interval))
  done
}

# Asks Argo CD to re-read git right away and then to sync.
request_sync() {
  argocd_api "$application_url?refresh=hard" > /dev/null
  # Auto-sync may already be running; a rejected manual sync is fine then.
  argocd_api -X POST -H "Content-Type: application/json" -d '{}' "$application_url/sync" > /dev/null \
    || echo "Manual sync was rejected (probably already syncing); continuing"
}

# Succeeds once the application is Synced to the expected revision and Healthy for several checks in a row.
wait_until_healthy() {
  local waited=0 good_checks=0
  local response sync_status synced_revision health_status operation_phase

  while [ "$waited" -lt "$healthy_timeout" ]; do
    response=$(argocd_api "$application_url")
    sync_status=$(jq -r '.status.sync.status' <<< "$response")
    synced_revision=$(jq -r '.status.sync.revision' <<< "$response")
    health_status=$(jq -r '.status.health.status' <<< "$response")
    operation_phase=$(jq -r '.status.operationState.phase // ""' <<< "$response")
    echo "sync=$sync_status revision=${synced_revision:0:7} health=$health_status operation=$operation_phase (${waited}s)"

    if [ "$operation_phase" = "Failed" ] || [ "$operation_phase" = "Error" ]; then
      echo "::error::Argo CD operation $operation_phase"
      exit 1
    fi

    if [ "$sync_status" = "Synced" ] && [ "$health_status" = "Healthy" ] && [ "$synced_revision" = "$expected_revision" ]; then
      good_checks=$((good_checks + 1))
    else
      good_checks=0
    fi
    if [ "$good_checks" -ge "$healthy_checks_required" ]; then
      echo "$application is synced to ${expected_revision:0:7} and healthy"
      return
    fi

    sleep "$healthy_interval"
    waited=$((waited + healthy_interval))
  done

  echo "::error::$application was not healthy at ${expected_revision:0:7} within ${healthy_timeout}s"
  exit 1
}

wait_until_application_exists
request_sync
wait_until_healthy
