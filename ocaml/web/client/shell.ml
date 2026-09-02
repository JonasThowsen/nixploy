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

let menu_icon () = icon [ "M4 7h16"; "M4 12h16"; "M4 17h16" ]

let page_copy = function
  | Route.Home -> ("Overview", "Nixploy")
  | Apps -> ("Applications", "Nixploy")
  | Application key -> (Route.Application_key.to_string key, "Application")
  | Telemetry -> ("Host health", "Nixploy")
  | Not_found _ -> ("Not found", "Nixploy")

let nav_link ~route ~target ~navigate ~label ~section_active =
  let active = Route.equal route target || section_active in
  Ui_helpers.route_link
    ~class_name:("nav-link" ^ if active then " nav-link-active" else "")
    ~route:target ~navigate
    [ Vdom.Node.text label ]
  |> fun node ->
  if active then
    Vdom.Node.a
      ~attrs:
        (Browser_navigation.link_attrs target ~on_navigate:navigate
        @ [
            Vdom.Attr.class_ "nav-link nav-link-active";
            Vdom.Attr.create "aria-current" "page";
          ])
      [ Vdom.Node.text label ]
  else node

let render ~route ~connection_label ~connection_class ~mobile_open ~navigate
    ~on_toggle_mobile ~on_close_mobile ~notice ~content =
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
            [ Vdom.Node.strong [ Vdom.Node.text "nixploy" ] ];
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
          nav_link ~route ~target:Route.Home ~navigate ~label:"Overview"
            ~section_active:false;
          nav_link ~route ~target:Route.Apps ~navigate ~label:"Applications"
            ~section_active:(Route.is_apps_section route);
          nav_link ~route ~target:Route.Telemetry ~navigate ~label:"Host health"
            ~section_active:false;
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
