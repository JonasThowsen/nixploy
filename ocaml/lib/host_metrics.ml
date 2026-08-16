open Async
open Core

type t = {
  cpu_percent : float;
  memory_used_bytes : int64;
  memory_total_bytes : int64;
  filesystem_used_bytes : int64;
  filesystem_total_bytes : int64;
  load_1 : float;
  load_5 : float;
  load_15 : float;
  uptime_seconds : int64;
}

let cpu_percent t = t.cpu_percent
let memory_used_bytes t = t.memory_used_bytes
let memory_total_bytes t = t.memory_total_bytes
let filesystem_used_bytes t = t.filesystem_used_bytes
let filesystem_total_bytes t = t.filesystem_total_bytes
let load_1 t = t.load_1
let load_5 t = t.load_5
let load_15 t = t.load_15
let uptime_seconds t = t.uptime_seconds

let script =
  {|
set -eu
printf 'NIXPLOY_CPU1\n'
cat /proc/stat
sleep 0.2
printf 'NIXPLOY_CPU2\n'
cat /proc/stat
printf 'NIXPLOY_MEMORY\n'
cat /proc/meminfo
printf 'NIXPLOY_LOAD\n'
cat /proc/loadavg
printf 'NIXPLOY_UPTIME\n'
cat /proc/uptime
printf 'NIXPLOY_FILESYSTEM\n'
LC_ALL=C df -B1 --output=size,used,avail /
|}

let sections output =
  let add sections name lines =
    match name with
    | None -> sections
    | Some name -> (name, List.rev lines) :: sections
  in
  let name, lines, result =
    List.fold (String.split_lines output) ~init:(None, [], [])
      ~f:(fun (name, lines, result) line ->
        if String.is_prefix line ~prefix:"NIXPLOY_" then
          (Some line, [], add result name lines)
        else (name, line :: lines, result))
  in
  add result name lines

let section sections name =
  List.Assoc.find sections ~equal:String.equal name
  |> Option.value_map
       ~default:(Or_error.errorf "host metrics section %s is missing" name)
       ~f:Or_error.return

let cpu_sample lines =
  let open Or_error.Let_syntax in
  let%bind line =
    List.find lines ~f:(String.is_prefix ~prefix:"cpu ")
    |> Option.value_map
         ~default:(Or_error.error_string "aggregate CPU counters are missing")
         ~f:Or_error.return
  in
  let values =
    String.split line ~on:' '
    |> List.filter ~f:(Fn.non String.is_empty)
    |> List.tl |> Option.value ~default:[]
  in
  let%bind counters =
    if List.length values < 4 then
      Or_error.error_string "aggregate CPU counters are incomplete"
    else Or_error.try_with (fun () -> List.map values ~f:Int64.of_string)
  in
  let total = List.fold counters ~init:0L ~f:Int64.( + ) in
  let idle =
    Int64.(
      List.nth_exn counters 3 + Option.value (List.nth counters 4) ~default:0L)
  in
  Ok (total, idle)

let memory lines =
  let value name =
    List.find_map lines ~f:(fun line ->
        match String.lsplit2 line ~on:':' with
        | Some (key, value) when String.equal key name ->
            String.split (String.strip value) ~on:' '
            |> List.hd
            |> Option.map ~f:Int64.of_string
        | _ -> None)
    |> Option.value_map
         ~default:(Or_error.errorf "%s is missing from /proc/meminfo" name)
         ~f:Or_error.return
  in
  let open Or_error.Let_syntax in
  let%bind total_kib = value "MemTotal" in
  let%map available_kib = value "MemAvailable" in
  let total = Int64.(total_kib * 1_024L) in
  (Int64.((total_kib - available_kib) * 1_024L), total)

let loads lines =
  let open Or_error.Let_syntax in
  let%bind line =
    List.find lines ~f:(Fn.non (Fn.compose String.is_empty String.strip))
    |> Option.value_map
         ~default:(Or_error.error_string "/proc/loadavg is empty")
         ~f:Or_error.return
  in
  match String.split line ~on:' ' with
  | one :: five :: fifteen :: _ ->
      Or_error.try_with (fun () ->
          (Float.of_string one, Float.of_string five, Float.of_string fifteen))
  | _ -> Or_error.error_string "/proc/loadavg is malformed"

let uptime lines =
  let open Or_error.Let_syntax in
  let%bind line =
    List.hd lines
    |> Option.value_map
         ~default:(Or_error.error_string "/proc/uptime is empty")
         ~f:Or_error.return
  in
  Or_error.try_with (fun () ->
      String.split line ~on:' ' |> List.hd_exn |> Float.of_string
      |> Float.iround_down_exn |> Int64.of_int)

let filesystem lines =
  let open Or_error.Let_syntax in
  let%bind values =
    List.filter_map lines ~f:(fun line ->
        let fields =
          String.split (String.strip line) ~on:' '
          |> List.filter ~f:(Fn.non String.is_empty)
        in
        match fields with
        | [ total; used; _available ] -> Some (total, used)
        | _ -> None)
    |> List.last
    |> Option.value_map
         ~default:(Or_error.error_string "filesystem metrics are malformed")
         ~f:Or_error.return
  in
  Or_error.try_with (fun () ->
      let total, used = values in
      (Int64.of_string used, Int64.of_string total))

let parse output =
  let open Or_error.Let_syntax in
  let sections = sections output in
  let%bind cpu1 = section sections "NIXPLOY_CPU1" >>= cpu_sample in
  let%bind cpu2 = section sections "NIXPLOY_CPU2" >>= cpu_sample in
  let%bind memory_used_bytes, memory_total_bytes =
    section sections "NIXPLOY_MEMORY" >>= memory
  in
  let%bind load_1, load_5, load_15 =
    section sections "NIXPLOY_LOAD" >>= loads
  in
  let%bind uptime_seconds = section sections "NIXPLOY_UPTIME" >>= uptime in
  let%bind filesystem_used_bytes, filesystem_total_bytes =
    section sections "NIXPLOY_FILESYSTEM" >>= filesystem
  in
  let total_delta = Int64.(fst cpu2 - fst cpu1) in
  let idle_delta = Int64.(snd cpu2 - snd cpu1) in
  let%bind cpu_percent =
    if Int64.(total_delta <= 0L || idle_delta < 0L) then
      Or_error.error_string "CPU counters did not advance"
    else
      Ok
        (Int64.to_float Int64.(total_delta - idle_delta)
        /. Int64.to_float total_delta *. 100.)
  in
  Ok
    {
      cpu_percent;
      memory_used_bytes;
      memory_total_bytes;
      filesystem_used_bytes;
      filesystem_total_bytes;
      load_1;
      load_5;
      load_15;
      uptime_seconds;
    }

let observe target =
  let open Deferred.Or_error.Let_syntax in
  let%bind result =
    Remote_command.run ~target ~timeout:(Time_ns.Span.of_sec 15.)
      ~max_output_bytes:262_144 [ "sh"; "-c"; script ]
  in
  match result.exit_status with
  | Error failure ->
      Deferred.Or_error.errorf "host metrics failed (%s): %s"
        (Core_unix.Exit_or_signal.to_string_hum (Error failure))
        (String.strip result.stderr)
  | Ok () -> Deferred.return (parse result.stdout)

module For_testing = struct
  let parse = parse
end
