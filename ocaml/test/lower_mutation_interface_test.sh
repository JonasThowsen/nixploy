#!/usr/bin/env bash
set -euo pipefail

ocamlfind=$1
library=$2
build_lib=$(dirname "$library")
include="$build_lib/.nixploy.objs/byte"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

must_not_compile() {
  name=$1
  source=$2
  printf '%s\n' "$source" > "$tmp/$name.ml"
  if "$ocamlfind" ocamlc -package core,async -I "$include" -c "$tmp/$name.ml" >"$tmp/$name.out" 2>&1; then
    echo "unsafe linked interface compiled: $name" >&2
    exit 1
  fi
}

must_not_compile application_deploy \
  'let _ = Nixploy.Application.deploy'
must_not_compile application_prune \
  'let _ = Nixploy.Application.prune'
must_not_compile deployment_authorize \
  'let _ = Nixploy.Deployment.authorize_managed'
must_not_compile deployment_prepare_without_request \
  'let f () : Nixploy.Deployment.prepared Async.Deferred.Or_error.t = Nixploy.Deployment.prepare ()'
must_not_compile deployment_execute_without_request \
  'let f operation_id prepared : Nixploy.Deployment.t Async.Deferred.Or_error.t = Nixploy.Deployment.execute ~operation_id prepared'
must_not_compile deployment_deploy_without_request \
  'let f operation_id : Nixploy.Deployment.t Async.Deferred.Or_error.t = Nixploy.Deployment.deploy ~operation_id ()'
must_not_compile tracked_deploy_without_request \
  'let f store : Nixploy.Store.deployment Async.Deferred.Or_error.t = Nixploy.Tracked_deployment.deploy ~store ()'
must_not_compile tracked_within_lease_without_request \
  'let f store : Nixploy.Store.deployment Async.Deferred.Or_error.t = Nixploy.Tracked_deployment.deploy_within_lease ~store ()'
for module in Managed_application Source_authority Operation_receipt Deployment_intent Deployment_receipt_store Control_plane_authority Managed_deployment_admission Host_metrics Runtime_application Protected_git Target_lease Target_lease_broker Target_lease_client Target_lease_socket Target_lease_state; do
  must_not_compile "removed_$module" "let identity (value : Nixploy.$module.t) = value"
done
for operation in preview_managed_deployment admit_managed_deployment start_managed_deployment application_metrics application_logs managed_scope; do
  must_not_compile "removed_$operation" "let operation = Nixploy.Application.$operation"
done

echo 'lower mutation interfaces require a deployment-specific request'
