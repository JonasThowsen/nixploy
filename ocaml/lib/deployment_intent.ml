open Core

type identity_policy = Canonical_only | Migration_candidates
[@@deriving compare, equal, sexp]

type destination = {
  host : string;
  user : string;
  port : int;
  kind : Managed_application.destination_kind;
  domain : string option;
  coordination_scope : string option;
}
[@@deriving equal]

type t = {
  application_key : string;
  project : Project_name.t;
  target : Target_name.t;
  repository_identity : string;
  repository_provenance : string option;
  revision : string;
  configuration_digest : string;
  destination : destination;
  resource_key : Resource_key.t;
  identity_policy : identity_policy;
}
[@@deriving equal]

let resource_key t = t.resource_key
let identity_policy t = t.identity_policy

let destination_of_target target ~coordination_scope =
  let kind, domain =
    match Configuration.Target.kind target with
    | Non_web -> (Managed_application.Non_web, None)
    | Web web -> (Managed_application.Web, Some (Configuration.Web.domain web))
  in
  {
    host = Configuration.Target.host target;
    user = Configuration.Target.user target;
    port = Configuration.Target.port target;
    kind;
    domain;
    coordination_scope;
  }

let validate_production application target =
  match
    ( Managed_application.production_destination application,
      Configuration.Target.production target )
  with
  | None, None ->
      Ok
        ( destination_of_target target ~coordination_scope:None,
          Migration_candidates )
  | Some expected, Some production ->
      let actual =
        destination_of_target target
          ~coordination_scope:
            (Some (Configuration.Production.coordination_scope production))
      in
      let expected_destination =
        {
          host = Managed_application.destination_host expected;
          user = Managed_application.destination_user expected;
          port = Managed_application.destination_port expected;
          kind = Managed_application.destination_kind expected;
          domain = Managed_application.destination_domain expected;
          coordination_scope =
            Some (Managed_application.coordination_scope expected);
        }
      in
      if not (equal_destination actual expected_destination) then
        Or_error.error_string
          "production destination mismatch between root-managed application \
           and evaluated target"
      else if String.equal actual.user "root" then
        Or_error.error_string "production destination SSH user must not be root"
      else Ok (actual, Canonical_only)
  | Some _, None ->
      Or_error.error_string
        "root-managed production destination requires targets.<name>.production"
  | None, Some _ ->
      Or_error.error_string
        "evaluated production target is not authorized by a root-managed \
         production destination"

let create ~application ~repository_origin ~revision ~configuration
    ~configuration_json =
  let open Or_error.Let_syntax in
  let expected_project = Managed_application.project application in
  let project = Configuration.project configuration in
  let%bind () =
    if Project_name.equal expected_project project then Ok ()
    else
      Or_error.error_string
        "managed project mismatch: evaluated configuration project differs \
         from the allowlisted project"
  in
  let target_name = Managed_application.target application in
  let%bind target = Configuration.find_target configuration target_name in
  let%bind destination, identity_policy =
    validate_production application target
  in
  let expected_provenance =
    Managed_application.repository_provenance application
  in
  let%bind () =
    match (expected_provenance, repository_origin) with
    | Some expected, Some actual when String.equal expected actual -> Ok ()
    | Some _, Some _ ->
        Or_error.error_string
          "managed repository provenance does not match Git remote.origin.url"
    | Some _, None ->
        Or_error.error_string
          "managed repository provenance requires an explicit Git \
           remote.origin.url"
    | None, _ ->
        Or_error.error_string
          "managed deployment preview requires explicit repository provenance"
  in
  let repository_identity =
    Managed_application.repository_identity application
  in
  let%map resource_key =
    Resource_key.derive ~project ~target:target_name ~repository_identity
  in
  {
    application_key = Managed_application.key application;
    project;
    target = target_name;
    repository_identity;
    repository_provenance = expected_provenance;
    revision;
    configuration_digest =
      Digestif.SHA256.digest_string configuration_json |> Digestif.SHA256.to_hex;
    destination;
    resource_key;
    identity_policy;
  }

let validate_evaluated expected ~repository_origin ~revision ~configuration
    ~configuration_json =
  let application_matches =
    Project_name.equal expected.project (Configuration.project configuration)
  in
  let open Or_error.Let_syntax in
  let%bind target = Configuration.find_target configuration expected.target in
  let actual_destination, actual_policy =
    match Configuration.Target.production target with
    | None ->
        ( destination_of_target target ~coordination_scope:None,
          Migration_candidates )
    | Some production ->
        ( destination_of_target target
            ~coordination_scope:
              (Some (Configuration.Production.coordination_scope production)),
          Canonical_only )
  in
  let actual_digest =
    Digestif.SHA256.digest_string configuration_json |> Digestif.SHA256.to_hex
  in
  let provenance_matches =
    Option.equal String.equal expected.repository_provenance repository_origin
  in
  if
    application_matches
    && String.equal expected.revision revision
    && String.equal expected.configuration_digest actual_digest
    && equal_destination expected.destination actual_destination
    && equal_identity_policy expected.identity_policy actual_policy
    && provenance_matches
  then Ok ()
  else
    Or_error.error_string
      "deployment preview intent no longer matches authoritative evaluated \
       intent"
