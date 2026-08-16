open Core

type ('query, 'value) entry = {
  query : 'query;
  value : 'value option;
  error : Error.t option;
}

type ('query, 'value) t = ('query, 'value) entry list

let empty = []

let find ~equal_query observations query =
  List.find observations ~f:(fun entry -> equal_query entry.query query)

let update ~equal_query observations ~query ~response =
  let previous = find ~equal_query observations query in
  let value, error =
    match response with
    | Ok (Ok value) -> (Some value, None)
    | Error error | Ok (Error error) ->
        (Option.bind previous ~f:(fun entry -> entry.value), Some error)
  in
  { query; value; error }
  :: List.filter observations ~f:(fun entry ->
      not (equal_query entry.query query))

let value ~equal_query observations ~query =
  find ~equal_query observations query
  |> Option.bind ~f:(fun entry -> entry.value)

let error ~equal_query observations ~query =
  find ~equal_query observations query
  |> Option.bind ~f:(fun entry -> entry.error)
