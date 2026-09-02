#!/usr/bin/env bash
set -euo pipefail

app=$1
application_page=$2
apps_page=$3

if grep -Fq 'Protocol.Deploy.t' "$app"; then
  echo 'browser app must not dispatch the revision-less Deploy RPC' >&2
  exit 1
fi

if grep -Fq 'Protocol.Deploy.Query' "$application_page" \
  || grep -Fq 'dispatch_deploy' "$application_page"; then
  echo 'application page must not construct or receive a revision-less deploy request' >&2
  exit 1
fi

grep -Fq 'Managed deployment unavailable' "$application_page"
grep -Fq 'source custody provides a verified full revision' "$application_page"

if grep -Fq 'deploy the current managed revision' "$apps_page"; then
  echo 'applications page must not promise unavailable managed deployment' >&2
  exit 1
fi

grep -Fq 'Managed deployment is unavailable' "$apps_page"
grep -Fq 'custody provides a verified full revision' "$apps_page"

echo 'managed browser deployment remains unavailable without a verified revision'
