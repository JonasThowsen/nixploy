open Core

type t = {
  working_directory : string;
  source : Source.selection;
  target : Target_name.t;
  expected_project : Project_name.t option;
  mutable claimed : bool;
  mutable operation_id : string option;
}

let create ?expected_project ~working_directory ~source ~target () =
  let%map.Or_error working_directory =
    Or_error.try_with (fun () -> Filename_unix.realpath working_directory)
  in
  {
    working_directory;
    source;
    target;
    expected_project;
    claimed = false;
    operation_id = None;
  }

let working_directory t = t.working_directory
let source t = t.source
let target t = t.target
let expected_project t = t.expected_project

let claim t =
  if t.claimed then
    Or_error.error_string "deployment request was already claimed"
  else (
    t.claimed <- true;
    Ok ())

let bind_operation t ~operation_id =
  if not t.claimed then
    Or_error.error_string
      "deployment request must be claimed before operation binding"
  else
    match t.operation_id with
    | None ->
        t.operation_id <- Some operation_id;
        Ok ()
    | Some _ ->
        Or_error.error_string
          "deployment request is already bound to an operation"

let validate_operation t ~operation_id =
  match t.operation_id with
  | Some expected when String.equal expected operation_id -> Ok ()
  | Some _ ->
      Or_error.error_string "deployment request does not match this operation"
  | None -> Or_error.error_string "deployment request has no bound operation"
