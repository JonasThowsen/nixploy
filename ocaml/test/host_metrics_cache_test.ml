open Async
open Core
open Nixploy.Host_metrics

let assert_ok = function
  | Ok value -> value
  | Error error -> failwith (Error.to_string_hum error)

let target ?(user = "root") ?host_key_fingerprint () =
  let host_key_fingerprint =
    Option.value_map host_key_fingerprint ~default:"null" ~f:(sprintf "\"%s\"")
  in
  let configuration =
    sprintf
      {|{"__schema":"v0.4","project":"sample","targets":{"production":{"image":"image","ip":"HOST.example.","user":"%s","port":2222,"hostKeyFingerprint":%s,"nonProduction":{"coordinationScope":"sample-production"}}}}|}
      user host_key_fingerprint
    |> Nixploy.Configuration.of_json |> assert_ok
  in
  Nixploy.Configuration.find_target configuration
    (Nixploy.Target_name.of_string "production" |> assert_ok)
  |> assert_ok

let metric =
  Nixploy.Host_metrics.For_testing.parse
    {|
NIXPLOY_CPU1
cpu  100 0 0 100 0
NIXPLOY_CPU2
cpu  120 0 0 100 0
NIXPLOY_MEMORY
MemTotal:       100 kB
MemAvailable:   50 kB
NIXPLOY_LOAD
1.00 2.00 3.00 1/1 1
NIXPLOY_UPTIME
12.00 0.00
NIXPLOY_FILESYSTEM
Size Used Avail
100 40 60
|}
  |> assert_ok

let run () =
  let fingerprint = "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" in
  assert (
    Result.is_error
      (Nixploy.Configuration.of_json
         {|{"__schema":"v0.4","project":"sample","targets":{"production":{"image":"image","ip":"host.example","hostKeyFingerprint":"SHA256:not-a-fingerprint"}}}|}));
  [%test_eq: int] 262_144
    Nixploy.Host_metrics.For_testing.maximum_command_output_bytes;
  let missing_identity_calls = ref 0 in
  let missing_identity_cache =
    Nixploy.Host_metrics.For_testing.create_cache ~now:(fun () -> Time_ns.epoch)
      ~fresh_for:(Time_ns.Span.of_sec 1.) ~stale_for:(Time_ns.Span.of_sec 10.)
      ~observe:(fun _ ->
        Int.incr missing_identity_calls;
        Deferred.Or_error.return metric)
      ()
  in
  let%bind missing =
    Nixploy.Host_metrics.For_testing.observe_cached missing_identity_cache
      (target ())
  in
  (match missing with
  | Nixploy.Host_metrics.Unavailable error ->
      assert (
        String.is_substring (Error.to_string_hum error)
          ~substring:"NIXPLOY_HOST_KEY_FINGERPRINT_REQUIRED")
  | Fresh _ | Stale _ -> failwith "missing SSH identity opened an observation");
  [%test_eq: int] 0 !missing_identity_calls;
  let partition_calls = ref 0 in
  let partition_cache =
    Nixploy.Host_metrics.For_testing.create_cache ~now:(fun () -> Time_ns.epoch)
      ~fresh_for:(Time_ns.Span.of_sec 1.) ~stale_for:(Time_ns.Span.of_sec 10.)
      ~observe:(fun _ ->
        Int.incr partition_calls;
        Deferred.Or_error.return metric)
      ()
  in
  let root_target = target ~host_key_fingerprint:fingerprint () in
  let deploy_target =
    target ~user:"deploy" ~host_key_fingerprint:fingerprint ()
  in
  assert (
    not
      (String.equal
         (Nixploy.Host_metrics.cache_key root_target |> assert_ok)
         (Nixploy.Host_metrics.cache_key deploy_target |> assert_ok)));
  let%bind root_observation =
    Nixploy.Host_metrics.For_testing.observe_cached partition_cache root_target
  in
  let%bind deploy_observation =
    Nixploy.Host_metrics.For_testing.observe_cached partition_cache deploy_target
  in
  (match (root_observation, deploy_observation) with
  | Fresh _, Fresh _ -> ()
  | (Stale _ | Unavailable _), _ | _, (Stale _ | Unavailable _) ->
      failwith "distinct SSH users must have independent fresh observations");
  [%test_eq: int] 2 !partition_calls;
  let waiter_first = Ivar.create () in
  let waiter_cache =
    Nixploy.Host_metrics.For_testing.create_cache ~now:(fun () -> Time_ns.epoch)
      ~fresh_for:(Time_ns.Span.of_sec 1.) ~stale_for:(Time_ns.Span.of_sec 10.)
      ~observe:(fun _ -> Ivar.read waiter_first) ()
  in
  let first_wait =
    Nixploy.Host_metrics.For_testing.observe_cached waiter_cache
      (target ~host_key_fingerprint:fingerprint ())
  in
  let coalesced_waits =
    List.init 32 ~f:(fun _ ->
        Nixploy.Host_metrics.For_testing.observe_cached waiter_cache
          (target ~host_key_fingerprint:fingerprint ()))
  in
  let%bind waiter_overflow =
    Nixploy.Host_metrics.For_testing.observe_cached waiter_cache
      (target ~host_key_fingerprint:fingerprint ())
  in
  (match waiter_overflow with
  | Unavailable error ->
      assert (
        String.is_substring (Error.to_string_hum error)
          ~substring:"NIXPLOY_HOST_METRICS_WAITERS_EXCEEDED")
  | Fresh _ | Stale _ -> failwith "the 33rd coalesced waiter must be refused");
  Ivar.fill_exn waiter_first (Ok metric);
  let%bind _ = Deferred.all (first_wait :: coalesced_waits) in
  let now = ref Time_ns.epoch in
  let calls = ref 0 in
  let first = Ivar.create () in
  let observe _ =
    Int.incr calls;
    if Int.equal !calls 1 then Ivar.read first
    else Deferred.Or_error.error_string "remote refresh failed"
  in
  let cache =
    Nixploy.Host_metrics.For_testing.create_cache ~now:(fun () -> !now)
      ~fresh_for:(Time_ns.Span.of_sec 1.) ~stale_for:(Time_ns.Span.of_sec 10.)
      ~observe ()
  in
  let configured = target ~host_key_fingerprint:fingerprint () in
  let one = Nixploy.Host_metrics.For_testing.observe_cached cache configured in
  let two = Nixploy.Host_metrics.For_testing.observe_cached cache configured in
  [%test_eq: int] 1 !calls;
  Ivar.fill_exn first (Ok metric);
  let%bind one = one and two = two in
  (match (one, two) with
  | Fresh _, Fresh _ -> ()
  | _ -> failwith "single-flight initial observations must be fresh");
  now := Time_ns.add !now (Time_ns.Span.of_sec 2.);
  let%bind stale =
    Nixploy.Host_metrics.For_testing.observe_cached cache configured
  in
  (match stale with
  | Stale (sample, error) ->
      [%test_eq: float] (Nixploy.Host_metrics.cpu_percent metric)
        (Nixploy.Host_metrics.cpu_percent
           (Nixploy.Host_metrics.sample_value sample));
      assert (String.is_substring (Error.to_string_hum error) ~substring:"refresh")
  | Fresh _ | Unavailable _ -> failwith "failed bounded refresh must retain stale data");
  let%map throttled =
    Nixploy.Host_metrics.For_testing.observe_cached cache configured
  in
  [%test_eq: int] 2 !calls;
  match throttled with
  | Stale _ -> ()
  | Fresh _ | Unavailable _ ->
      failwith "failed refresh must be throttled for the fresh interval"

let () =
  don't_wait_for
    (Monitor.try_with run >>| function
      | Ok () -> Shutdown.shutdown 0
      | Error error ->
          eprintf "%s\n" (Exn.to_string error);
          Shutdown.shutdown 1);
  never_returns (Scheduler.go ())
