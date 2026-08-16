open! Core
open! Bonsai_web.Cont

let icon paths =
  Vdom.Node.create_svg "svg"
    ~attrs:
      [
        Vdom.Attr.create "viewBox" "0 0 24 24";
        Vdom.Attr.create "fill" "none";
        Vdom.Attr.create "stroke" "currentColor";
        Vdom.Attr.create "stroke-width" "1.8";
        Vdom.Attr.create "stroke-linecap" "round";
        Vdom.Attr.create "stroke-linejoin" "round";
        Vdom.Attr.create "aria-hidden" "true";
      ]
    (List.map paths ~f:(fun path ->
         Vdom.Node.create_svg "path" ~attrs:[ Vdom.Attr.create "d" path ] []))

let home_icon () = icon [ "M3 11.5 12 4l9 7.5"; "M5.5 10v10h13V10" ]
let apps_icon () = icon [ "M4 5h16v6H4z"; "M4 15h16v4H4z"; "M8 8h.01" ]
let telemetry_icon () = icon [ "M4 19V9"; "M10 19V5"; "M16 19v-7"; "M22 19V3" ]
let menu_icon () = icon [ "M4 7h16"; "M4 12h16"; "M4 17h16" ]
let exact_active route target = Route.equal route target

let nav_link ~route ~target ~navigate ~label ~icon_node ~section_active =
  let exact = exact_active route target in
  Ui_helpers.route_link
    ~class_name:
      ("nav-link" ^ if exact || section_active then " nav-link-active" else "")
    ~route:target ~navigate
    [ icon_node; Vdom.Node.span [ Vdom.Node.text label ] ]
  |> fun node ->
  if exact then
    Vdom.Node.a
      ~attrs:
        (Browser_navigation.link_attrs target ~on_navigate:navigate
        @ [
            Vdom.Attr.class_ "nav-link nav-link-active";
            Vdom.Attr.create "aria-current" "page";
          ])
      [ icon_node; Vdom.Node.span [ Vdom.Node.text label ] ]
  else node

let application_link ~route ~application ~navigate =
  match
    Route.Application_key.of_string application.Protocol.Application.key
  with
  | Error _ -> Vdom.Node.none
  | Ok key ->
      let target = Route.Application key in
      let active = Route.equal route target in
      Vdom.Node.a ~key:application.key
        ~attrs:
          (Browser_navigation.link_attrs target ~on_navigate:navigate
          @ [
              Vdom.Attr.class_
                ("rail-app" ^ if active then " rail-app-active" else "");
            ]
          @ if active then [ Vdom.Attr.create "aria-current" "page" ] else [])
        [
          Vdom.Node.span
            ~attrs:
              [
                Vdom.Attr.class_ "rail-app-dot";
                Vdom.Attr.create "aria-hidden" "true";
              ]
            [];
          Vdom.Node.span
            [
              Vdom.Node.strong [ Vdom.Node.text application.key ];
              Vdom.Node.small
                [
                  Vdom.Node.text
                    (application.project ^ " · " ^ application.target);
                ];
            ];
        ]

let page_copy route =
  match route with
  | Route.Home -> ("Overview", "Control plane")
  | Apps -> ("Applications", "Recognized sources")
  | Application key ->
      (Route.Application_key.to_string key, "Application workspace")
  | Telemetry -> ("Telemetry", "Hosts and runtimes")
  | Not_found _ -> ("Not found", "Unknown route")

let render ~route ~applications ~connection_label ~connection_class ~mobile_open
    ~navigate ~on_toggle_mobile ~on_close_mobile ~notice ~content =
  let heading, context = page_copy route in
  Vdom.Node.div
    ~attrs:[ Vdom.Attr.class_ "app-shell" ]
    [
      Vdom.Node.header
        ~attrs:[ Vdom.Attr.class_ "top-header" ]
        [
          Vdom.Node.button
            ~attrs:
              [
                Vdom.Attr.id "mobile-menu-button";
                Vdom.Attr.class_ "mobile-menu-button";
                Vdom.Attr.create "type" "button";
                Vdom.Attr.create "aria-label"
                  (if mobile_open then "Close navigation" else "Open navigation");
                Vdom.Attr.create "aria-controls" "primary-navigation";
                Vdom.Attr.create "aria-expanded" (Bool.to_string mobile_open);
                Vdom.Attr.on_click (fun _ -> on_toggle_mobile);
              ]
            [ menu_icon () ];
          Ui_helpers.route_link ~class_name:"brand" ~route:Route.Home ~navigate
            [
              Vdom.Node.span
                ~attrs:[ Vdom.Attr.class_ "brand-mark" ]
                [ Vdom.Node.text "N" ];
              Vdom.Node.span
                [
                  Vdom.Node.strong [ Vdom.Node.text "nixploy" ];
                  Vdom.Node.small [ Vdom.Node.text "Bonsai control plane" ];
                ];
            ];
          Vdom.Node.div
            ~attrs:[ Vdom.Attr.class_ "header-context" ]
            [
              Vdom.Node.span [ Vdom.Node.text context ];
              Vdom.Node.h1
                ~attrs:[ Vdom.Attr.id "page-heading" ]
                [ Vdom.Node.text heading ];
            ];
          Vdom.Node.div
            ~attrs:
              [
                Vdom.Attr.classes [ "connection-pill"; connection_class ];
                Vdom.Attr.create "role" "status";
                Vdom.Attr.create "aria-live" "polite";
              ]
            [
              Vdom.Node.span
                ~attrs:
                  [
                    Vdom.Attr.class_ "status-dot";
                    Vdom.Attr.create "aria-hidden" "true";
                  ]
                [];
              Vdom.Node.span [ Vdom.Node.text connection_label ];
            ];
        ];
      Vdom.Node.button
        ~attrs:
          [
            Vdom.Attr.class_
              ("navigation-scrim" ^ if mobile_open then " visible" else "");
            Vdom.Attr.create "type" "button";
            Vdom.Attr.create "aria-label" "Close navigation";
            Vdom.Attr.create "tabindex" "-1";
            Vdom.Attr.on_click (fun _ -> on_close_mobile);
          ]
        [];
      Vdom.Node.create "nav"
        ~attrs:
          [
            Vdom.Attr.id "primary-navigation";
            Vdom.Attr.class_
              ("navigation-rail" ^ if mobile_open then " mobile-open" else "");
            Vdom.Attr.create "aria-label" "Primary navigation";
            Vdom.Attr.create "tabindex" "-1";
          ]
        [
          Vdom.Node.div
            ~attrs:[ Vdom.Attr.class_ "navigation-index" ]
            [
              Vdom.Node.div
                ~attrs:[ Vdom.Attr.class_ "primary-links" ]
                [
                  nav_link ~route ~target:Route.Home ~navigate ~label:"Home"
                    ~icon_node:(home_icon ()) ~section_active:false;
                  nav_link ~route ~target:Route.Apps ~navigate
                    ~label:"Applications" ~icon_node:(apps_icon ())
                    ~section_active:(Route.is_apps_section route);
                  nav_link ~route ~target:Route.Telemetry ~navigate
                    ~label:"Telemetry" ~icon_node:(telemetry_icon ())
                    ~section_active:false;
                ];
              Vdom.Node.div
                ~attrs:[ Vdom.Attr.class_ "rail-applications" ]
                ([
                   Vdom.Node.p
                     ~attrs:[ Vdom.Attr.class_ "rail-label" ]
                     [ Vdom.Node.text "Applications" ];
                 ]
                @
                match applications with
                | Some values ->
                    if List.is_empty values then
                      [
                        Vdom.Node.p
                          ~attrs:[ Vdom.Attr.class_ "rail-empty" ]
                          [ Vdom.Node.text "No recognized applications" ];
                      ]
                    else
                      List.map values ~f:(fun application ->
                          application_link ~route ~application ~navigate)
                | None ->
                    [
                      Vdom.Node.p
                        ~attrs:[ Vdom.Attr.class_ "rail-empty" ]
                        [ Vdom.Node.text "Loading applications…" ];
                    ]);
            ];
          Vdom.Node.p
            ~attrs:[ Vdom.Attr.class_ "rail-footnote" ]
            [
              Vdom.Node.text "Immutable Git revisions · remote Podman runtimes";
            ];
        ];
      Vdom.Node.main
        ~attrs:
          ([
             Vdom.Attr.id "main-content";
             Vdom.Attr.class_ "content-region";
             Vdom.Attr.create "tabindex" "-1";
           ]
          @ if mobile_open then [ Vdom.Attr.create "inert" "" ] else [])
        [
          (if String.is_empty notice then Vdom.Node.none
           else
             Vdom.Node.div
               ~attrs:
                 [
                   Vdom.Attr.class_ "notice";
                   Vdom.Attr.create "role" "status";
                   Vdom.Attr.create "aria-live" "polite";
                 ]
               [ Vdom.Node.text notice ]);
          content;
        ];
    ]
