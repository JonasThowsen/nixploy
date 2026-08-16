open Core

type ('query, 'value) t

val empty : ('query, 'value) t

val update :
  equal_query:('query -> 'query -> bool) ->
  ('query, 'value) t ->
  query:'query ->
  response:'value Or_error.t Or_error.t ->
  ('query, 'value) t

val value :
  equal_query:('query -> 'query -> bool) ->
  ('query, 'value) t ->
  query:'query ->
  'value option

val error :
  equal_query:('query -> 'query -> bool) ->
  ('query, 'value) t ->
  query:'query ->
  Error.t option
