(*---------------------------------------------------------------------------
   Copyright (c) 2016 Daniel C. Bünzli. All rights reserved.
   Distributed under the ISC license, see terms at the end of the file.
   %%NAME%% %%VERSION%%
  ---------------------------------------------------------------------------*)

open Bos_setup

module D = struct
  let user = "${user}"

  let repo = "${repo}"

  let dir = Fpath.v "${dir}"

  let fetch_head = "${fetch_head}"

  let token = "${token}"

  let pr_url = "${pr_url}"

  let download_url = "${download_url}"

  let release_id = 1
end

(* Publish documentation *)

let publish_in_git_branch ~dry_run ~remote ~branch ~name ~version ~docdir ~dir
    ~yes =
  let pp_distrib ppf (name, version) =
    Fmt.pf ppf "%a %a" Text.Pp.name name Text.Pp.version version
  in
  let log_publish_result msg distrib dir =
    App_log.success (fun m ->
        m "%s %a in directory %a of gh-pages branch" msg pp_distrib distrib
          Fpath.pp dir)
  in
  let delete dir =
    if not (Fpath.is_current_dir dir) then Sos.delete_dir ~dry_run dir
    else
      let delete acc p = acc >>= fun () -> Sos.delete_path ~dry_run p in
      let gitdir = Fpath.v ".git" in
      let not_git p = not (Fpath.equal p gitdir) in
      OS.Dir.contents dir >>= fun files ->
      List.fold_left delete (Ok ()) (List.filter not_git files)
  in
  let replace_dir_and_push docdir dir =
    let msg = strf "Update %s doc to %s." name version in
    Vcs.get () >>= fun repo ->
    Vcs.run_git_quiet repo ~dry_run ~force:(dir <> D.dir)
      Cmd.(v "checkout" % branch)
    >>= fun () ->
    delete dir >>= fun () ->
    Sos.cp ~dry_run ~rec_:true ~force:true ~src:Fpath.(docdir / ".") ~dst:dir
    >>= fun () ->
    (if dry_run then Ok true else Vcs.is_dirty repo) >>= function
    | false -> Ok false
    | true ->
        Vcs.run_git_quiet repo ~dry_run Cmd.(v "add" % p dir) >>= fun () ->
        Vcs.run_git_quiet repo ~dry_run Cmd.(v "commit" % "-m" % msg)
        >>= fun () ->
        Vcs.run_git_quiet repo ~dry_run Cmd.(v "push") >>= fun () -> Ok true
  in
  if not (Fpath.is_rooted ~root:Fpath.(v ".") dir) then
    R.error_msgf "%a directory is not rooted in the repository or not relative"
      Fpath.pp dir
  else
    let clonedir = Fpath.(parent (parent (parent docdir)) / "gh-pages") in
    Sos.delete_dir ~dry_run ~force:true clonedir >>= fun () ->
    Vcs.get () >>= fun repo ->
    Vcs.clone ~dry_run ~force:true ~dir:clonedir repo >>= fun () ->
    Sos.relativize ~src:clonedir ~dst:docdir >>= fun rel_docdir ->
    App_log.status (fun l ->
        l "Updating local %a branch" Text.Pp.commit "gh-pages");
    Sos.with_dir ~dry_run clonedir (replace_dir_and_push rel_docdir) dir
    >>= fun res ->
    res >>= function
    | false (* no changes *) ->
        log_publish_result "No documentation changes for" (name, version) dir;
        Ok ()
    | true ->
        let push_spec = strf "%s:%s" branch branch in
        Prompt.(
          confirm_or_abort ~yes
            ~question:(fun l ->
              l "Push new documentation to %a?" Text.Pp.url
                (remote ^ "#gh-pages"))
            ~default_answer:Yes)
        >>= fun () ->
        App_log.status (fun l ->
            l "Pushing new documentation to %a" Text.Pp.url
              (remote ^ "#gh-pages"));
        Vcs.run_git_quiet repo ~dry_run Cmd.(v "push" % remote % push_spec)
        >>= fun () ->
        Sos.delete_dir ~dry_run clonedir >>= fun () ->
        log_publish_result "Published documentation for" (name, version) dir;
        Ok ()

let publish_doc ~dry_run ~msg:_ ~docdir ~yes p =
  ( if dry_run then Ok D.(user, repo, dir)
  else
    Pkg.Github.doc_uri p >>= fun { user; repo; path; _ } ->
    let dir = Stdext.Option.value path ~default:(Fpath.v ".") in
    Ok (user, repo, dir) )
  >>= fun (user, repo, dir) ->
  Pkg.name p >>= fun name ->
  Pkg.version p >>= fun version ->
  let remote =
    let scheme = Github_uri.Repo_scheme.GIT and git_ext = true in
    Github_uri.Repo.(to_string @@ make ~user ~repo ~scheme ~git_ext)
  in
  Vcs.get () >>= fun vcs ->
  let force = user <> D.user in
  let create_empty_gh_pages () =
    let msg = "Initial commit by dune-release." in
    let create () =
      Vcs.run_git_quiet vcs ~dry_run Cmd.(v "init") >>= fun () ->
      Vcs.run_git_quiet vcs ~dry_run
        Cmd.(v "checkout" % "--orphan" % "gh-pages")
      >>= fun () ->
      Sos.write_file ~dry_run (Fpath.v "README") ""
      (* need some file *) >>= fun () ->
      Vcs.run_git_quiet vcs ~dry_run Cmd.(v "add" % "README") >>= fun () ->
      Vcs.run_git_quiet vcs ~dry_run Cmd.(v "commit" % "README" % "-m" % msg)
    in
    OS.Dir.with_tmp "gh-pages-%s.tmp"
      (fun dir () ->
        Sos.with_dir ~dry_run dir create () |> R.join >>= fun () ->
        Vcs.run_git_quiet vcs ~dry_run ~force
          Cmd.(v "fetch" % Fpath.to_string dir % "gh-pages"))
      ()
    |> R.join
  in
  ( match
      Vcs.run_git_quiet vcs ~dry_run ~force
        Cmd.(v "fetch" % remote % "gh-pages")
    with
  | Ok () -> Ok ()
  | Error _ ->
      App_log.status (fun l ->
          l "Creating new gh-pages branch with inital commit on %s/%s" user repo);
      create_empty_gh_pages () )
  >>= fun () ->
  Vcs.run_git_string vcs ~dry_run ~force
    Cmd.(v "rev-parse" % "FETCH_HEAD")
    ~default:(Sos.out D.fetch_head)
  >>= fun id ->
  Vcs.run_git_quiet vcs ~dry_run ~force
    Cmd.(v "branch" % "-f" % "gh-pages" % id)
  >>= fun () ->
  publish_in_git_branch ~dry_run ~remote ~branch:"gh-pages" ~name ~version
    ~docdir ~dir ~yes

(* Publish releases *)

let github_auth ~dry_run ~user token =
  if dry_run then Ok Curl_option.{ user; token = D.token }
  else Sos.read_file ~dry_run token >>| fun token -> Curl_option.{ user; token }

let run_with_auth ?(default_body = `Null) ~dry_run ~auth curl_t =
  let Curl.{ url; args } = Curl.with_auth ~auth curl_t in
  let args = Curl_option.to_string_list args in
  if dry_run then
    Sos.show "exec:@[@ curl %a@]"
      Format.(pp_print_list ~pp_sep:pp_print_space pp_print_string)
      args
    >>| fun () -> default_body
  else
    OS.Cmd.must_exist (Cmd.v "curl") >>= fun _ ->
    let req = Curly.Request.make ~url ~meth:`POST () in
    Logs.debug (fun l ->
        l "[curl] executing request:@;<1 2>%a" Curly.Request.pp req);
    Logs.debug (fun l ->
        l "[curl] with args:@;<1 2>%a" (Fmt.list ~sep:Fmt.sp Fmt.string) args);
    match Curly.run ~args req with
    | Ok resp ->
        Logs.debug (fun l ->
            l "[curl] response received:@;<1 2>%a" Curly.Response.pp resp);
        Json.from_string resp.body
    | Error e -> R.error_msgf "curl execution failed: %a" Curly.Error.pp e

let curl_create_release ~token ~dry_run version msg user repo =
  github_auth ~dry_run ~user token >>= fun auth ->
  let curl_t = Curl.create_release ~version ~msg ~user ~repo in
  let default_body = `Assoc [ ("id", `Int D.release_id) ] in
  run_with_auth ~dry_run ~default_body ~auth curl_t
  >>= Github_v3_api.Release_response.release_id

let curl_upload_archive ~token ~dry_run ~yes archive user repo release_id =
  let curl_t = Curl.upload_archive ~archive ~user ~repo ~release_id in
  github_auth ~dry_run ~user token >>= fun auth ->
  let default_body =
    `Assoc [ ("browser_download_url", `String D.download_url) ]
  in
  Prompt.try_again ~yes ~default_answer:Prompt.Yes
    ~question:(fun l ->
      l "Uploading %a as release asset failed. Try again?" Text.Pp.path archive)
    (fun () ->
      run_with_auth ~dry_run ~default_body ~auth curl_t
      >>= Github_v3_api.Upload_response.browser_download_url)

let open_pr ~token ~dry_run ~title ~distrib_user ~user ~branch ~opam_repo body =
  let curl_t = Curl.open_pr ~title ~user ~branch ~body ~opam_repo in
  github_auth ~dry_run ~user:distrib_user token >>= fun auth ->
  let default_body = `Assoc [ ("html_url", `String D.pr_url) ] in
  run_with_auth ~dry_run ~default_body ~auth curl_t
  >>= Github_v3_api.Pull_request_response.html_url

let dev_repo p =
  Pkg.dev_repo p >>= function
  | Some r -> Ok r
  | None ->
      Pkg.opam p >>= fun opam ->
      R.error_msgf "The field dev-repo is missing in %a." Fpath.pp opam

let check_tag ~dry_run vcs tag =
  if Vcs.tag_exists ~dry_run vcs tag then Ok ()
  else
    R.error_msgf
      "CHANGES.md lists '%s' as the latest release, but no corresponding tag \
       has been found in the repository.@.Did you forget to call 'dune-release \
       tag' ?"
      tag

let assert_tag_exists ~dry_run tag =
  Vcs.get () >>= fun repo ->
  if Vcs.tag_exists ~dry_run repo tag then Ok ()
  else R.error_msgf "%s is not a valid tag" tag

let publish_distrib ?token ?distrib_uri ~dry_run ~msg ~archive ~yes p =
  (match distrib_uri with Some uri -> Ok uri | None -> Pkg.infer_distrib_uri p)
  >>= fun uri ->
  ( match Pkg.Github.distrib_uri uri with
  | Error _ as e -> if dry_run then Ok (D.user, D.repo) else e
  | Ok { user; repo; _ } -> Ok (user, repo) )
  >>= fun (user, repo) ->
  Pkg.tag p >>= fun tag ->
  assert_tag_exists ~dry_run tag >>= fun () ->
  Vcs.get () >>= fun vcs ->
  Pkg.tag p >>= fun tag ->
  check_tag ~dry_run vcs tag >>= fun () ->
  dev_repo p >>= fun upstr ->
  Prompt.(
    confirm_or_abort ~yes
      ~question:(fun l ->
        l "Push tag %a to %a?" Text.Pp.version tag Text.Pp.url upstr)
      ~default_answer:Yes)
  >>= fun () ->
  App_log.status (fun l ->
      l "Pushing tag %a to %a" Text.Pp.version tag Text.Pp.url upstr);
  Vcs.run_git_quiet vcs ~dry_run Cmd.(v "push" % "--force" % upstr % tag)
  >>= fun () ->
  (match token with Some t -> Ok t | None -> Config.token ~dry_run ())
  >>= fun token ->
  Prompt.(
    confirm_or_abort ~yes
      ~question:(fun l ->
        l "Create release %a on %a?" Text.Pp.version tag Text.Pp.url upstr)
      ~default_answer:Yes)
  >>= fun () ->
  App_log.status (fun l ->
      l "Creating release %a on %a via github's API" Text.Pp.version tag
        Text.Pp.url upstr);
  curl_create_release ~token ~dry_run tag msg user repo >>= fun id ->
  App_log.success (fun l -> l "Succesfully created release with id %d" id);
  Prompt.(
    confirm_or_abort ~yes
      ~question:(fun l -> l "Upload %a as release asset?" Text.Pp.path archive)
      ~default_answer:Yes)
  >>= fun () ->
  App_log.status (fun l ->
      l "Uploading %a as a release asset for %a via github's API" Text.Pp.path
        archive Text.Pp.version tag);
  curl_upload_archive ~token ~dry_run ~yes archive user repo id

(*---------------------------------------------------------------------------
   Copyright (c) 2016 Daniel C. Bünzli

   Permission to use, copy, modify, and/or distribute this software for any
   purpose with or without fee is hereby granted, provided that the above
   copyright notice and this permission notice appear in all copies.

   THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
   WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
   MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
   ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
   WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
   ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
   OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
  ---------------------------------------------------------------------------*)
