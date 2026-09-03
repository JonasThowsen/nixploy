#!/usr/bin/env bash
set -euo pipefail

app=$1
application_page=$2
apps_page=$3

if grep -Fq 'Protocol.Deploy.t' "$app"; then
  echo 'browser app must dispatch the grant-bearing Deploy V1 RPC' >&2
  exit 1
fi

grep -Fq 'Protocol.Deploy.V1.t' "$app"
grep -Fq 'dispatch_deploy' "$application_page"
grep -Fq 'Deploy' "$application_page"
grep -Fq 'deploy it' "$apps_page"

if grep -Fq 'Managed deployment is unavailable' "$application_page" \
  || grep -Fq 'Managed deployment is unavailable' "$apps_page"; then
  echo 'browser deployment must not retain the managed-unavailable fence' >&2
  exit 1
fi

echo 'browser deploy dispatches the grant-bearing shared deployment RPC'
