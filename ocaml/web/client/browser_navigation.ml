open! Core
open! Bonsai_web.Cont
open Js_of_ocaml

type listener = {
  target : Js.Unsafe.any;
  name : string;
  callback : Js.Unsafe.any;
}

type application_owner = { key : string; route_epoch : int }

let listeners : listener list ref = ref []
let route_epoch = ref 0
let dispatch action = Vdom.Effect.Expert.handle_non_dom_event_exn action

let listen target name callback =
  let callback = Js.Unsafe.inject callback in
  ignore
    (Js.Unsafe.meth_call target "addEventListener"
       [| Js.Unsafe.inject (Js.string name); callback |]);
  listeners := { target; name; callback } :: !listeners

let cleanup_now () =
  List.iter !listeners ~f:(fun listener ->
      ignore
        (Js.Unsafe.meth_call listener.target "removeEventListener"
           [| Js.Unsafe.inject (Js.string listener.name); listener.callback |]));
  listeners := []

let current_path () =
  let location = Js.Unsafe.get (Js.Unsafe.inject Dom_html.window) "location" in
  let pathname : Js.js_string Js.t = Js.Unsafe.get location "pathname" in
  Js.to_string pathname

let current_parsed () = Route.parse_path (current_path ())
let initial_route () = (current_parsed ()).route

let application_owner key =
  Effect.of_deferred_thunk (fun () ->
      Async_kernel.Deferred.return { key; route_epoch = !route_epoch })

let is_current_owner owner =
  Int.equal owner.route_epoch !route_epoch
  &&
  match (current_parsed ()).route with
  | Route.Application current ->
      String.equal (Route.Application_key.to_string current) owner.key
  | Home | Apps | Telemetry | Not_found _ -> false

let present value =
  Js.to_bool
    (Js.Unsafe.coerce
       (Js.Unsafe.fun_call
          (Js.Unsafe.get (Js.Unsafe.inject Dom_html.window) "Boolean")
          [| value |]))

let element_by_id id =
  Js.Unsafe.meth_call
    (Js.Unsafe.inject Dom_html.document)
    "getElementById"
    [| Js.Unsafe.inject (Js.string id) |]

let element_has_class id class_name =
  let element = element_by_id id in
  if not (present element) then false
  else
    let class_list = Js.Unsafe.get element "classList" in
    Js.to_bool
      (Js.Unsafe.coerce
         (Js.Unsafe.meth_call class_list "contains"
            [| Js.Unsafe.inject (Js.string class_name) |]))

let schedule_main_scroll_to_top () =
  let callback =
    Js.wrap_callback (fun () ->
        let element = element_by_id "main-content" in
        if present element then Js.Unsafe.set element "scrollTop" 0)
  in
  ignore
    (Js.Unsafe.meth_call
       (Js.Unsafe.inject Dom_html.window)
       "requestAnimationFrame"
       [| Js.Unsafe.inject callback |])

let history_call method_name path =
  let history = Js.Unsafe.get (Js.Unsafe.inject Dom_html.window) "history" in
  ignore
    (Js.Unsafe.meth_call history method_name
       [|
         Js.Unsafe.inject Js.null;
         Js.Unsafe.inject (Js.string "");
         Js.Unsafe.inject (Js.string path);
       |])

let canonicalize parsed =
  Option.iter parsed.Route.canonical_path ~f:(history_call "replaceState")

let set_document_title_now route =
  let title = Route.page_title route ^ " · nixploy" in
  Js.Unsafe.set
    (Js.Unsafe.inject Dom_html.document)
    "title"
    (Js.Unsafe.inject (Js.string title))

let start ~on_route ~on_escape =
  Effect.of_deferred_thunk (fun () ->
      cleanup_now ();
      let window = Js.Unsafe.inject Dom_html.window in
      let parsed = current_parsed () in
      canonicalize parsed;
      set_document_title_now parsed.route;
      dispatch (on_route parsed.route);
      let popstate =
        Js.wrap_callback (fun _ ->
            Int.incr route_epoch;
            let parsed = current_parsed () in
            canonicalize parsed;
            dispatch (on_route parsed.route);
            schedule_main_scroll_to_top ())
      in
      listen window "popstate" popstate;
      let resize =
        Js.wrap_callback (fun _ ->
            let inner_width : float = Js.Unsafe.get window "innerWidth" in
            if
              Float.(inner_width > 760.)
              && element_has_class "primary-navigation" "mobile-open"
            then dispatch (on_escape ()))
      in
      listen window "resize" resize;
      let keydown =
        Js.wrap_callback (fun event ->
            let key : Js.js_string Js.t = Js.Unsafe.get event "key" in
            if
              String.equal (Js.to_string key) "Escape"
              && element_has_class "primary-navigation" "mobile-open"
            then dispatch (on_escape ()))
      in
      listen (Js.Unsafe.inject Dom_html.document) "keydown" keydown;
      Async_kernel.Deferred.return ())

let cleanup () =
  Effect.of_deferred_thunk (fun () ->
      cleanup_now ();
      Async_kernel.Deferred.return ())

let push route =
  Effect.of_deferred_thunk (fun () ->
      history_call "pushState" (Route.to_path route);
      Int.incr route_epoch;
      Async_kernel.Deferred.return ())

let set_document_title route =
  Effect.of_deferred_thunk (fun () ->
      set_document_title_now route;
      Async_kernel.Deferred.return ())

let scroll_main_to_top () =
  Effect.of_deferred_thunk (fun () ->
      schedule_main_scroll_to_top ();
      Async_kernel.Deferred.return ())

let event_bool event name =
  Js.to_bool (Js.Unsafe.coerce (Js.Unsafe.get (Js.Unsafe.inject event) name))

let event_int event name : int = Js.Unsafe.get (Js.Unsafe.inject event) name

let ordinary_click event =
  Int.equal (event_int event "button") 0
  && (not (event_bool event "metaKey"))
  && (not (event_bool event "ctrlKey"))
  && (not (event_bool event "shiftKey"))
  && (not (event_bool event "altKey"))
  && not (event_bool event "defaultPrevented")

let link_attrs route ~on_navigate =
  [
    Vdom.Attr.href (Route.to_path route);
    Vdom.Attr.on_click (fun event ->
        if ordinary_click event then
          Effect.Many [ Vdom.Effect.Prevent_default; on_navigate route ]
        else Effect.Ignore);
  ]

let focus id =
  Effect.of_deferred_thunk (fun () ->
      let callback =
        Js.wrap_callback (fun () ->
            let element = element_by_id id in
            if present element then
              ignore (Js.Unsafe.meth_call element "focus" [||]))
      in
      ignore
        (Js.Unsafe.meth_call
           (Js.Unsafe.inject Dom_html.window)
           "requestAnimationFrame"
           [| Js.Unsafe.inject callback |]);
      Async_kernel.Deferred.return ())
