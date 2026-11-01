open Core

type t = Time_ns.t

type fields = {
  year : int;
  month : int;
  day : int;
  hour : int;
  minute : int;
  second : int;
  nanoseconds : int;
  offset_seconds : int;
}

(* RFC 3339 section 5.6 date-time: full-date "T" time-hour ":" time-minute ":"
   time-second [time-secfrac] time-offset, where "T" and "Z" may be lowercase.
   Fractions longer than nanoseconds are refused rather than rounded. *)
let parse value =
  let open Option.Let_syntax in
  let length = String.length value in
  let character_is position allowed =
    position < length && String.mem allowed value.[position]
  in
  let expect position allowed =
    Option.some_if (character_is position allowed) ()
  in
  let number ~pos ~len =
    if pos + len > length then None
    else
      let field = String.sub value ~pos ~len in
      if String.for_all field ~f:Char.is_digit then Some (Int.of_string field)
      else None
  in
  let%bind year = number ~pos:0 ~len:4 in
  let%bind () = expect 4 "-" in
  let%bind month = number ~pos:5 ~len:2 in
  let%bind () = expect 7 "-" in
  let%bind day = number ~pos:8 ~len:2 in
  let%bind () = expect 10 "Tt" in
  let%bind hour = number ~pos:11 ~len:2 in
  let%bind () = expect 13 ":" in
  let%bind minute = number ~pos:14 ~len:2 in
  let%bind () = expect 16 ":" in
  let%bind second = number ~pos:17 ~len:2 in
  let%bind nanoseconds, zone_position =
    if character_is 19 "." then
      let digits =
        String.drop_prefix value 20
        |> String.take_while ~f:Char.is_digit
        |> String.length
      in
      if digits < 1 || digits > 9 then None
      else
        let%map fraction = number ~pos:20 ~len:digits in
        (fraction * Int.pow 10 (9 - digits), 20 + digits)
    else Some (0, 19)
  in
  let%bind offset_seconds =
    if character_is zone_position "Zz" && zone_position + 1 = length then Some 0
    else if character_is zone_position "+-" && zone_position + 6 = length then
      let%bind offset_hours = number ~pos:(zone_position + 1) ~len:2 in
      let%bind () = expect (zone_position + 3) ":" in
      let%bind offset_minutes = number ~pos:(zone_position + 4) ~len:2 in
      let%map () =
        Option.some_if (offset_hours <= 23 && offset_minutes <= 59) ()
      in
      let sign = if Char.equal value.[zone_position] '-' then -1 else 1 in
      sign * ((offset_hours * 3600) + (offset_minutes * 60))
    else None
  in
  Some { year; month; day; hour; minute; second; nanoseconds; offset_seconds }

(* Time_ns covers roughly 1823 to 2116; a log time outside 1970 to 2100 is a
   typing mistake, so it is refused instead of reaching that limit. Second 60
   is refused because Podman does not accept leap seconds. *)
let in_range fields =
  fields.year >= 1970 && fields.year <= 2100 && fields.month >= 1
  && fields.month <= 12 && fields.day >= 1
  && fields.day
     <= Date.days_in_month ~year:fields.year
          ~month:(Month.of_int_exn fields.month)
  && fields.hour <= 23 && fields.minute <= 59 && fields.second <= 59

let of_fields fields =
  let date =
    Date.create_exn ~y:fields.year
      ~m:(Month.of_int_exn fields.month)
      ~d:fields.day
  in
  let ofday =
    Time_ns.Ofday.create ~hr:fields.hour ~min:fields.minute ~sec:fields.second
      ~ns:fields.nanoseconds ()
  in
  Time_ns.sub
    (Time_ns.of_date_ofday ~zone:Time_float.Zone.utc date ofday)
    (Time_ns.Span.of_int_sec fields.offset_seconds)

let of_string value =
  match parse value with
  | Some fields when in_range fields -> Ok (of_fields fields)
  | Some _ | None ->
      Or_error.errorf
        "since time %S is not an RFC 3339 instant such as 2026-11-01T10:00:00Z"
        (String.prefix value 64)

let to_string t =
  let date, ofday = Time_ns.to_date_ofday t ~zone:Time_float.Zone.utc in
  let since_midnight = Time_ns.Ofday.to_span_since_start_of_day ofday in
  let nanoseconds = Time_ns.Span.to_int_ns since_midnight % 1_000_000_000 in
  let fraction =
    if nanoseconds = 0 then ""
    else "." ^ String.rstrip (sprintf "%09d" nanoseconds) ~drop:(Char.equal '0')
  in
  sprintf "%sT%s%sZ" (Date.to_string date)
    (Time_ns.Ofday.to_sec_string ofday)
    fraction
