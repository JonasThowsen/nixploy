open Core
module Authority = Nixploy.Control_plane_authority

let valid =
  {|
((version 1)
 (authorities
  (((alias netcup)
    (uri https://control.example.invalid:443)
    (pinned_server_spki_sha256 AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=)
    (trusted_proxy_authority https://control.example.invalid)))))
|}

let metadata ?(uid = 0) ?(perm = 0o755) ?(regular = false)
    ?(directory = false) ?(device = 1) ?(inode = 1) ?(size = 0)
    ?(modified_at = 0.) () : Authority.For_testing.metadata =
  { uid; perm; regular; directory; device; inode; size; modified_at }

let protected_directory () = metadata ~directory:true ()

let filesystem ~file_metadata ~read ~directory_metadata :
    Authority.For_testing.filesystem =
  {
    lstat =
      (fun path ->
        if String.equal path "/etc/nixploy/control-plane-authorities.sexp" then
          Ok file_metadata
        else directory_metadata path);
    read;
  }

let load filesystem =
  Authority.For_testing.load filesystem
    ~path:"/etc/nixploy/control-plane-authorities.sexp"

let () =
  let authority =
    Authority.For_testing.parse valid |> Or_error.ok_exn |> List.hd_exn
  in
  assert (String.equal (Authority.alias authority) "netcup");
  assert (
    String.equal
      (Uri.to_string (Authority.uri authority))
      "https://control.example.invalid:443");
  assert (
    Result.is_error
      (Authority.For_testing.parse
         {|
((version 1)
 (authorities
  (((alias netcup)
    (uri http://control.example.invalid)
    (pinned_server_spki_sha256 AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=)
    (trusted_proxy_authority https://control.example.invalid)))))
|}));
  assert (
    Result.is_error
      (Authority.For_testing.parse
         {|
((version 1)
 (authorities
  (((alias Netcup)
    (uri https://control.example.invalid)
    (pinned_server_spki_sha256 not-a-pin)
    (trusted_proxy_authority https://control.example.invalid)))))
|}));
  assert (
    Result.is_error
      (Authority.For_testing.parse {|
((version 2) (authorities ()))
|}));
  assert (Result.is_error (Authority.find [ authority ] ~alias:"unknown"));
  assert (
    Result.is_ok
      (Authority.For_testing.validate_file_metadata ~uid:0 ~perm:0o644
         ~regular:true));
  assert (
    Result.is_error
      (Authority.For_testing.validate_file_metadata ~uid:1000 ~perm:0o644
         ~regular:true));
  assert (
    Result.is_error
      (Authority.For_testing.validate_file_metadata ~uid:0 ~perm:0o664
         ~regular:true));
  assert (
    Result.is_error
      (Authority.For_testing.validate_file_metadata ~uid:0 ~perm:0o600
         ~regular:false));
  let protected_file =
    metadata ~regular:true ~perm:0o600 ~size:(String.length valid) ()
  in
  let stable_read _ = Ok (protected_file, valid, protected_file) in
  assert (
    Result.is_ok
      (load
         (filesystem ~file_metadata:protected_file ~read:stable_read
            ~directory_metadata:(fun _ -> Ok (protected_directory ()) ))));
  assert (
    Result.is_error
      (load
         (filesystem ~file_metadata:protected_file ~read:stable_read
            ~directory_metadata:(fun path ->
              if String.equal path "/etc/nixploy" then
                Ok (metadata ~directory:true ~perm:0o775 ())
              else Ok (protected_directory ()) ))));
  assert (
    Result.is_error
      (load
         (filesystem ~file_metadata:protected_file ~read:stable_read
            ~directory_metadata:(fun path ->
              if String.equal path "/etc/nixploy" then Ok (metadata ())
              else Ok (protected_directory ()) ))));
  let replaced_file = { protected_file with inode = 2 } in
  assert (
    Result.is_error
      (load
         (filesystem ~file_metadata:protected_file
            ~read:(fun _ -> Ok (protected_file, valid, replaced_file))
            ~directory_metadata:(fun _ -> Ok (protected_directory ()) ))))
