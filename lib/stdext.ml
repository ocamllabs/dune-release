open Bos_setup

module Sbytes = struct
  type t = Bytes.t

  let make size char =
    try R.ok (Bytes.make size char) with Invalid_argument e -> R.error_msg e

  let blit_string src srcoff dst dstoff len =
    try R.ok (Bytes.blit_string src srcoff dst dstoff len)
    with Invalid_argument e -> R.error_msg e
end

module Path = struct
  let is_backup_file str =
    let len = String.length str in
    len > 0
    &&
    let first = str.[0] in
    let last = str.[len - 1] in
    Char.equal last '~' || (Char.equal first '#' && Char.equal last '#')

  let find_files ~names_wo_ext files =
    let open Fpath in
    List.filter
      (fun file ->
        if is_backup_file (filename file) then false
        else
          let normalized = to_string (normalize (rem_ext file)) in
          List.exists
            (String.equal (String.Ascii.lowercase normalized))
            names_wo_ext)
      files
end

module Unix = struct
  let maybe_echo_input echo_input f x =
    if echo_input then f x
    else
      let open Unix in
      let term_io = tcgetattr stdin in
      tcsetattr stdin TCSANOW { term_io with c_echo = false };
      let input = f x in
      tcsetattr stdin TCSANOW term_io;
      input

  let read_line ?(echo_input = true) () =
    maybe_echo_input echo_input read_line ()
end

module Option = struct
  let pp pp_a fmt opt =
    match opt with
    | None -> Format.fprintf fmt "None"
    | Some a -> Format.fprintf fmt "Some %a" pp_a a

  let equal equal_a opt opt' =
    match (opt, opt') with
    | None, None -> true
    | Some a, Some a' -> equal_a a a'
    | _ -> false

  let map ~f = function None -> None | Some x -> Some (f x)

  let bind ~f = function None -> None | Some x -> f x

  let value ~default opt = match opt with Some x -> x | None -> default

  let to_result ~none = function None -> Error none | Some x -> Ok x

  module O = struct
    let ( >>= ) opt f = bind ~f opt

    let ( >|= ) opt f = map ~f opt
  end
end

module Result = struct
  module List = struct
    let iter ~f l =
      List.fold_left (fun acc x -> acc >>= fun () -> f x) (Ok ()) l
  end
end

module String = struct
  let pp fmt t = Format.fprintf fmt "%S" t
end

module List = struct
  let pp pp_a fmt l =
    match l with
    | [] -> Format.fprintf fmt "[]"
    | [ a ] -> Format.fprintf fmt "@[<hov 2>[ %a ]@]" pp_a a
    | hd :: tl ->
        Format.fprintf fmt "@[<hov 2>[ %a" pp_a hd;
        List.iter (fun a -> Format.fprintf fmt ";@ %a" pp_a a) tl;
        Format.fprintf fmt " ]@]"

  let rec equal equal_a l l' =
    match (l, l') with
    | [], [] -> true
    | hd :: tl, hd' :: tl' -> equal_a hd hd' && equal equal_a tl tl'
    | _, _ -> false

  let filter_map ~f l =
    let rec fmap acc = function
      | [] -> List.rev acc
      | hd :: tl -> (
          match f hd with None -> fmap acc tl | Some x -> fmap (x :: acc) tl)
    in
    fmap [] l
end
