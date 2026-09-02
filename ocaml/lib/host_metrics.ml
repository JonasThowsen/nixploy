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

let bounded_diagnostic value =
  String.prefix (String.strip value) 4_096

let observe_uncached target =
  let open Deferred.Or_error.Let_syntax in
  let%bind result =
    Remote_command.run ~target ~timeout:(Time_ns.Span.of_sec 15.)
      ~max_output_bytes:4_096 [ "sh"; "-c"; script ]
  in
  match result.exit_status with
  | Error failure ->
      Deferred.Or_error.errorf "host metrics failed (%s): %s"
        (Core_unix.Exit_or_signal.to_string_hum (Error failure))
        (bounded_diagnostic result.stderr)
  | Ok () -> Deferred.return (parse result.stdout)

type sample = { value : t; observed_at : Time_ns.t }
type observation = Fresh of sample | Stale of sample * Error.t | Unavailable of Error.t

type cached_observation = {
  mutable sample : sample option;
  mutable fresh_until : Time_ns.t;
  mutable stale_until : Time_ns.t;
  mutable retry_at : Time_ns.t;
  mutable last_error : Error.t option;
  mutable refresh : observation Deferred.t option;
  mutable waiters : int;
}

type cache = {
  now : unit -> Time_ns.t;
  fresh_for : Time_ns.Span.t;
  stale_for : Time_ns.Span.t;
  observe_uncached : Configuration.Target.t -> t Deferred.Or_error.t;
  entries : cached_observation String.Table.t;
}

let sample_value sample = sample.value
let sample_observed_at_ms sample =
  Time_ns.to_span_since_epoch sample.observed_at |> Time_ns.Span.to_ms
  |> Int64.of_float

let cache_key target =
  match Configuration.Target.host_key_fingerprint target with
  | None ->
      Or_error.error_string
        "NIXPLOY_HOST_KEY_FINGERPRINT_REQUIRED: target hostKeyFingerprint is required for remote observation"
  | Some fingerprint ->
      Ok
        (sprintf "%s:%d:%s" (Configuration.Target.host target)
           (Configuration.Target.port target) (Ssh_host_key.fingerprint fingerprint))

let create_cache ~now ~fresh_for ~stale_for ~observe () =
  { now; fresh_for; stale_for; observe_uncached = observe; entries = String.Table.create () }

let unavailable error = Deferred.return (Unavailable error)
let maximum_coalesced_waiters = 32

let await_refresh entry =
  match entry.refresh with
  | None -> assert false
  | Some _ when entry.waiters >= maximum_coalesced_waiters ->
      unavailable
        (Error.of_string
           "NIXPLOY_HOST_METRICS_WAITERS_EXCEEDED: observation refresh already has 32 coalesced waiters")
  | Some refresh ->
      entry.waiters <- entry.waiters + 1;
      upon refresh (fun _ -> entry.waiters <- entry.waiters - 1);
      refresh

let begin_observation cache ~key ~previous target =
  let entry =
    Option.value previous ~default:{
      sample = None;
      fresh_until = Time_ns.epoch;
      stale_until = Time_ns.epoch;
      retry_at = Time_ns.epoch;
      last_error = None;
      refresh = None;
      waiters = 0;
    }
  in
  let completed =
    let%map.Deferred result = cache.observe_uncached target in
    let observed_at = cache.now () in
    match result with
    | Ok value ->
        let sample = { value; observed_at } in
        entry.sample <- Some sample;
        entry.fresh_until <- Time_ns.add observed_at cache.fresh_for;
        entry.stale_until <- Time_ns.add observed_at cache.stale_for;
        entry.retry_at <- entry.fresh_until;
        entry.last_error <- None;
        Fresh sample
    | Error error ->
        entry.last_error <- Some error;
        entry.retry_at <- Time_ns.add observed_at cache.fresh_for;
        (match entry.sample with
        | Some sample when Time_ns.(observed_at <= entry.stale_until) ->
            Stale (sample, error)
        | Some _ | None -> Unavailable error)
  in
  entry.refresh <- Some completed;
  Hashtbl.set cache.entries ~key ~data:entry;
  upon completed (fun _ -> entry.refresh <- None);
  completed

let observe_cached cache target =
  match cache_key target with
  | Error error -> unavailable error
  | Ok key -> (
      match Hashtbl.find cache.entries key with
      | Some { sample = Some sample; fresh_until; _ }
        when Time_ns.(cache.now () <= fresh_until) ->
          Deferred.return (Fresh sample)
      | Some ({ refresh = Some _; _ } as entry) -> await_refresh entry
      | Some ({ sample = Some sample; retry_at; last_error = Some error; _ } as _entry)
        when Time_ns.(cache.now () < retry_at) ->
          Deferred.return (Stale (sample, error))
      | Some ({ sample = None; retry_at; last_error = Some error; _ } as _entry)
        when Time_ns.(cache.now () < retry_at) ->
          Deferred.return (Unavailable error)
      | Some entry -> begin_observation cache ~key ~previous:(Some entry) target
      | None -> begin_observation cache ~key ~previous:None target)

let default_cache =
  create_cache ~now:Time_ns.now ~fresh_for:(Time_ns.Span.of_sec 10.)
    ~stale_for:(Time_ns.Span.of_sec 30.) ~observe:observe_uncached ()

let observe target = observe_cached default_cache target

module For_testing = struct
  let parse = parse
  let create_cache = create_cache
  let observe_cached = observe_cached
end
