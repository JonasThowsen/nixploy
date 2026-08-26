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
  source_provenance : string option;
  source_reference : string option;
  source_evidence_digest : string option;
  revision : string;
  configuration_digest : string;
  destination : destination;
  resource_key : Resource_key.t;
  identity_policy : identity_policy;
}
[@@deriving equal]

let resource_key t = t.resource_key
let identity_policy t = t.identity_policy
let repository_identity t = t.repository_identity
let revision t = t.revision

let destination_of_target target =
  let kind, domain =
    match Configuration.Target.kind target with
    | Non_web -> (Managed_application.Non_web, None)
    | Web web -> (Managed_application.Web, Some (Configuration.Web.domain web))
  in
  let coordination_scope =
    match
      ( Configuration.Target.production target,
        Configuration.Target.non_production target )
    with
    | Some production, None ->
        Some (Configuration.Production.coordination_scope production)
    | None, Some non_production ->
        Some (Configuration.Non_production.coordination_scope non_production)
    | None, None -> None
    | Some _, Some _ ->
        raise_s [%message "configuration profile invariant violated"]
  in
  {
    host = Configuration.Target.host target;
    user = Configuration.Target.user target;
    port = Configuration.Target.port target;
    kind;
    domain;
    coordination_scope;
  }

let destination_of_contract contract =
  {
    host = Managed_application.destination_host contract;
    user = Managed_application.destination_user contract;
    port = Managed_application.destination_port contract;
    kind = Managed_application.destination_kind contract;
    domain = Managed_application.destination_domain contract;
    coordination_scope = Some (Managed_application.coordination_scope contract);
  }

let configuration_digest json =
  Digestif.SHA256.digest_string json |> Digestif.SHA256.to_hex

let validate_project application configuration =
  if
    Project_name.equal
      (Managed_application.project application)
      (Configuration.project configuration)
  then Ok ()
  else
    Or_error.error_string
      "managed project mismatch: evaluated configuration project differs from \
       the root-managed project"

let create ~application ~source_authority ~revision ~configuration
    ~configuration_json =
  let open Or_error.Let_syntax in
  let%bind () = validate_project application configuration in
  let target_name = Managed_application.target application in
  let%bind target = Configuration.find_target configuration target_name in
  let actual_destination = destination_of_target target in
  let%bind expected_destination, identity_policy =
    match
      ( Managed_application.production_destination application,
        Managed_application.non_production_destination application )
    with
    | Some contract, None ->
        let expected = destination_of_contract contract in
        if not (equal_destination actual_destination expected) then
          Or_error.error_string
            "production destination or coordination scope differs from the \
             root-managed authority"
        else Ok (expected, Canonical_only)
    | None, Some contract ->
        let expected = destination_of_contract contract in
        if not (equal_destination actual_destination expected) then
          Or_error.error_string
            "non-production destination differs from the root-managed authority"
        else Ok (expected, Migration_candidates)
    | Some _, Some _ ->
        Or_error.error_string
          "managed application has conflicting mutation policies"
    | None, None ->
        Or_error.error_string
          "managed application has no root-owned mutation policy"
  in
  let%bind source_provenance, source_reference, source_evidence_digest =
    match (identity_policy, source_authority) with
    | Canonical_only, Some authority ->
        let expected_provenance =
          Managed_application.repository_provenance application
          |> Option.value_exn
        in
        if
          not
            (String.equal expected_provenance
               (Source_authority.provenance authority))
        then
          Or_error.error_string
            "source authority provenance differs from the managed repository"
        else
          Ok
            ( Some (Source_authority.provenance authority),
              Some (Source_authority.reference authority),
              Some (Source_authority.evidence_digest authority) )
    | Canonical_only, None -> Ok (None, None, None)
    | Migration_candidates, None -> Ok (None, None, None)
    | Migration_candidates, Some _ ->
        Or_error.error_string
          "non-production intent unexpectedly carried production source \
           authority"
  in
  let project = Configuration.project configuration in
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
    source_provenance;
    source_reference;
    source_evidence_digest;
    revision;
    configuration_digest = configuration_digest configuration_json;
    destination = expected_destination;
    resource_key;
    identity_policy;
  }

let validate_application expected application =
  let contract_matches =
    match
      ( expected.identity_policy,
        Managed_application.production_destination application,
        Managed_application.non_production_destination application )
    with
    | Canonical_only, Some contract, None ->
        equal_destination expected.destination
          (destination_of_contract contract)
        && Option.equal String.equal expected.source_provenance
             (Managed_application.repository_provenance application)
        && Option.equal String.equal expected.source_reference
             (Managed_application.repository_reference application)
    | Migration_candidates, None, Some contract ->
        equal_destination expected.destination
          (destination_of_contract contract)
        && Option.is_none expected.source_provenance
        && Option.is_none expected.source_reference
        && Option.is_none expected.source_evidence_digest
    | Canonical_only, _, _ | Migration_candidates, _, _ -> false
  in
  if
    String.equal expected.application_key (Managed_application.key application)
    && Project_name.equal expected.project
         (Managed_application.project application)
    && Target_name.equal expected.target
         (Managed_application.target application)
    && String.equal expected.repository_identity
         (Managed_application.repository_identity application)
    && contract_matches
  then Ok ()
  else
    Or_error.error_string
      "deployment intent does not belong to this managed application"

let validate_evaluated expected ~source_authority ~revision ~configuration
    ~configuration_json =
  let open Or_error.Let_syntax in
  let%bind target = Configuration.find_target configuration expected.target in
  let actual_destination = destination_of_target target in
  let source_matches =
    match
      ( expected.source_provenance,
        expected.source_reference,
        expected.source_evidence_digest,
        source_authority )
    with
    | Some provenance, Some reference, Some digest, Some authority ->
        String.equal provenance (Source_authority.provenance authority)
        && String.equal reference (Source_authority.reference authority)
        && String.equal digest (Source_authority.evidence_digest authority)
    | None, None, None, None -> true
    | _ -> false
  in
  if
    Project_name.equal expected.project (Configuration.project configuration)
    && String.equal expected.revision revision
    && String.equal expected.configuration_digest
         (configuration_digest configuration_json)
    && equal_destination expected.destination actual_destination
    && source_matches
  then Ok ()
  else
    Or_error.error_string
      "deployment preview intent no longer matches authoritative source, \
       configuration, or destination intent"

let authorize_local ~applications:_ ~working_directory:_ ~configuration:_
    ~target:_ =
  (* A local checkout is the CLI source of truth. Managed application
     allowlists constrain the web surface, not direct local deployment. *)
  Ok Migration_candidates
