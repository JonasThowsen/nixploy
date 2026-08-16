open Core
module Last_good = Nixploy_web_client_state.Last_good

let equal_query = String.equal
let value state query = Last_good.value ~equal_query state ~query
let error state query = Last_good.error ~equal_query state ~query

let () =
  let state = Last_good.empty in
  assert (Option.is_none (value state "a"));
  assert (Option.is_none (error state "a"));
  let state =
    Last_good.update ~equal_query state ~query:"a" ~response:(Ok (Ok 1))
  in
  [%test_eq: int option] (Some 1) (value state "a");
  assert (Option.is_none (error state "a"));
  let inner_error = Error.of_string "application observation failed" in
  let state =
    Last_good.update ~equal_query state ~query:"a"
      ~response:(Ok (Error inner_error))
  in
  [%test_eq: int option] (Some 1) (value state "a");
  assert (Option.exists (error state "a") ~f:(Error.equal inner_error));
  let transport_error = Error.of_string "transport failed" in
  let state =
    Last_good.update ~equal_query state ~query:"b"
      ~response:(Error transport_error)
  in
  assert (Option.is_none (value state "b"));
  assert (Option.exists (error state "b") ~f:(Error.equal transport_error));
  [%test_eq: int option] (Some 1) (value state "a");
  assert (Option.exists (error state "a") ~f:(Error.equal inner_error));
  let state =
    Last_good.update ~equal_query state ~query:"a" ~response:(Ok (Ok 2))
  in
  [%test_eq: int option] (Some 2) (value state "a");
  assert (Option.is_none (error state "a"));
  assert (Option.exists (error state "b") ~f:(Error.equal transport_error))
