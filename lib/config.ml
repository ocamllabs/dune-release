(*
 * Copyright (c) 2018 Thomas Gazagnaire <thomas@gazagnaire.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Bos_setup

type t = {
  user : string option;
  remote : string option;
  local : Fpath.t option;
  keep_v : bool option;
  auto_open : bool option;
}

let empty =
  { user = None; remote = None; local = None; keep_v = None; auto_open = None }

let of_yaml str =
  Yaml.of_string str >>= function
  | `O dict ->
      let rec aux acc = function
        | [] -> Ok acc
        | ("user", `String s) :: t -> aux { acc with user = Some s } t
        | ("remote", `String s) :: t -> aux { acc with remote = Some s } t
        | ("local", `String s) :: t ->
            let local =
              match Fpath.of_string s with Ok x -> Some x | Error _ -> None
            in
            aux { acc with local } t
        | ("auto-open", `Bool b) :: t -> aux { acc with auto_open = Some b } t
        | ("keep-v", `Bool b) :: t -> aux { acc with keep_v = Some b } t
        | (key, _) :: _ ->
            R.error_msgf "%S is not a valid configuration key." key
      in
      aux empty dict
  | _ -> R.error_msg "invalid format"

let read_string default ~descr =
  let read () =
    match read_line () with
    | "" -> None
    | s ->
        print_newline ();
        Some s
    | exception End_of_file ->
        print_newline ();
        None
    | exception (Sys.Break as e) ->
        print_newline ();
        raise e
  in
  Fmt.pr "@[<h-0>%s@.[press ENTER to use '%a']@]\n%!" (String.trim descr)
    Fmt.(styled `Bold string)
    default;
  match read () with None -> default | Some s -> s

let create_config ~user ~remote_repo ~local_repo pkgs file =
  Fmt.pr
    "%a does not exist!\n\
     Please answer a few questions to help me create it for you:\n\n\
     %!"
    Fpath.pp file;
  (match user with
  | Some u -> Ok u
  | None ->
      let pkg = List.hd pkgs in
      Pkg.infer_repo_uri pkg >>= Uri.Github.get_user_and_repo >>= fun (u, _) ->
      Ok u)
  >>= fun default_user ->
  let user = read_string default_user ~descr:"What is your GitHub ID?" in
  let default_remote =
    Stdext.Option.value remote_repo
      ~default:(strf "git@github.com:%s/opam-repository" user)
  in
  let default_local =
    Stdext.Option.value local_repo
      ~default:Fpath.(v Xdg.home / "git" / "opam-repository" |> to_string)
  in
  let remote =
    read_string default_remote
      ~descr:
        "What is your fork of ocaml/opam-repository? (you should have write \
         access)."
  in
  let local =
    read_string default_local
      ~descr:"Where on your filesystem did you clone that repository?"
  in
  Fpath.of_string local >>= fun local_path ->
  Yaml.to_string
    (`O
      [
        ("user", `String user);
        ("remote", `String remote);
        ("local", `String local);
      ])
  >>= fun v ->
  OS.Dir.create Fpath.(parent file) >>= fun _ ->
  OS.File.write file v >>| fun () ->
  { empty with user = Some user; remote = Some remote; local = Some local_path }

let config_dir () =
  let cfg = Fpath.(v Xdg.config_dir / "dune") in
  let upgrade () =
    (* Upgrade from 0.2 to 0.3 format *)
    let old_d = Fpath.(v Xdg.home / ".dune") in
    OS.Dir.exists old_d >>= function
    | false -> Ok ()
    | true ->
        App_log.status (fun m ->
            m "Upgrading configuration files: %a => %a" Fpath.pp old_d Fpath.pp
              cfg);
        OS.Dir.create ~path:true cfg >>= fun _ ->
        OS.Path.move old_d Fpath.(cfg / "release.yml")
  in
  upgrade () >>= fun () -> Ok cfg

let file () = config_dir () >>| fun cfg -> Fpath.(cfg / "release.yml")

let find () =
  file () >>= fun file ->
  OS.File.exists file >>= fun exists ->
  if exists then OS.File.read file >>= of_yaml >>| fun x -> Some x else Ok None

let v ~user ~remote_repo ~local_repo pkgs =
  find () >>= function
  | Some f -> Ok f
  | None -> file () >>= create_config ~user ~remote_repo ~local_repo pkgs

let reset_terminal : (unit -> unit) option ref = ref None

let cleanup () = match !reset_terminal with None -> () | Some f -> f ()

let () = at_exit cleanup

let get_token () =
  let rec aux () =
    match Stdext.Unix.read_line ~echo_input:false () with
    | "" -> aux ()
    | s -> s
    | exception End_of_file ->
        print_newline ();
        aux ()
    | exception (Sys.Break as e) ->
        print_newline ();
        raise e
  in
  aux ()

let validate_token token =
  let token = String.trim token in
  if String.is_empty token || String.exists Char.Ascii.is_white token then
    Error (R.msg "token is malformed")
  else Ok token

let token ~dry_run () =
  config_dir () >>= fun cfg ->
  let file = Fpath.(cfg / "github.token") in
  OS.File.exists file >>= fun exists ->
  let is_valid =
    if exists then Sos.read_file ~dry_run file >>= validate_token
    else Error (R.msg "does not exist")
  in
  match is_valid with
  | Ok _ -> Ok file
  | Error (`Msg msg) ->
      if dry_run then Ok Fpath.(v "${token}")
      else
        let error = if exists then ":" ^ msg else " does not exist" in
        Fmt.pr
          "%a%s!\n\n\
           To create a new token, please visit:\n\n\
          \   https://github.com/settings/tokens/new\n\n\
           And create a token with a nice name and and the %a scope only.\n\n\
           Copy the token@ here: %!" Fpath.pp file error
          Fmt.(styled `Bold string)
          "public_repo";
        let rec get_valid_token () =
          match validate_token (get_token ()) with
          | Ok token -> token
          | Error (`Msg msg) ->
              Fmt.pr "Please try again, %s.%!" msg;
              get_valid_token ()
        in
        let token = get_valid_token () in
        OS.Dir.create Fpath.(parent file) >>= fun _ ->
        OS.File.write ~mode:0o600 file token >>= fun () -> Ok file

let load () = find () >>| Stdext.Option.value ~default:empty

let pretty_fields { user; remote; local; keep_v; auto_open } =
  [
    ("user", Stdext.Option.map ~f:(fun x -> `String x) user);
    ("remote", Stdext.Option.map ~f:(fun x -> `String x) remote);
    ("local", Stdext.Option.map ~f:(fun x -> `String (Fpath.to_string x)) local);
    ("keep-v", Stdext.Option.map ~f:(fun x -> `Bool x) keep_v);
    ("auto-open", Stdext.Option.map ~f:(fun x -> `Bool x) auto_open);
  ]

let save t =
  file () >>= fun file ->
  let fields = pretty_fields t in
  let content =
    Stdext.List.filter_map fields ~f:(function
      | _, None -> None
      | key, Some value -> Some (key, value))
  in
  Yaml.to_string (`O content) >>= fun v -> OS.File.write file v

let pp fmt t =
  let fields = pretty_fields t in
  let fields =
    List.map
      (function
        | key, None -> (key, "<unset>")
        | key, Some (`Bool b) -> (key, string_of_bool b)
        | key, Some (`String s) -> (key, s))
      fields
  in
  Format.pp_print_list
    ~pp_sep:(fun fs () -> Format.fprintf fs "\n")
    (fun fs (k, v) -> Format.fprintf fs "%s: %s" k v)
    fmt fields

let file = lazy (find ())

let read f default =
  Lazy.force file >>| function
  | None -> default
  | Some t -> ( match f t with None -> default | Some b -> b)

let keep_v v = if v then Ok true else read (fun t -> t.keep_v) false

let auto_open v = if not v then Ok false else read (fun t -> t.auto_open) true

module type S = sig
  val path : build_dir:Fpath.t -> name:string -> version:string -> Fpath.t

  val set :
    dry_run:bool ->
    build_dir:Fpath.t ->
    name:string ->
    version:string ->
    string ->
    (unit, R.msg) result

  val is_set :
    dry_run:bool ->
    build_dir:Fpath.t ->
    name:string ->
    version:string ->
    (bool, R.msg) result

  val get :
    dry_run:bool ->
    build_dir:Fpath.t ->
    name:string ->
    version:string ->
    (string, R.msg) result

  val unset :
    dry_run:bool ->
    build_dir:Fpath.t ->
    name:string ->
    version:string ->
    (unit, R.msg) result
end

module Make (X : sig
  val ext : string
end) =
struct
  let path ~build_dir ~name ~version =
    Fpath.(build_dir / strf "%s-%s.%s" name version X.ext)

  let set ~dry_run ~build_dir ~name ~version id =
    Sos.write_file ~dry_run (path ~build_dir ~name ~version) id

  let is_set ~dry_run ~build_dir ~name ~version =
    Sos.file_exists ~dry_run (path ~build_dir ~name ~version)

  let get ~dry_run ~build_dir ~name ~version =
    Sos.read_file ~dry_run (path ~build_dir ~name ~version)

  let unset ~dry_run ~build_dir ~name ~version =
    let path = path ~build_dir ~name ~version in
    Sos.file_exists ~dry_run path >>= fun exists ->
    if exists then Sos.delete_path ~dry_run path else Ok ()
end

module Draft_release = Make (struct
  let ext = "draft_release"
end)

module Draft_pr = Make (struct
  let ext = "draft_pr"
end)

module Release_asset_name = Make (struct
  let ext = "release_asset_name"
end)
