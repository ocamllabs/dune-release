open Bos_setup

(** Safe wrapping for some Bytes functions. *)
module Sbytes : sig
  type t = Bytes.t
  (** An alias for the type of byte sequences. *)

  val make : int -> char -> (t, [> R.msg ]) result
  (** [make n c] returns a new byte sequence of length [n], filled with the byte
      [c]. Returns an error message if [n < 0] or [n > Sys.max_string_length]. *)

  val blit_string :
    string -> int -> t -> int -> int -> (unit, [> R.msg ]) result
  (** [blit src srcoff dst dstoff len] copies [len] bytes from string [src],
      starting at index [srcoff], to byte sequence [dst], starting at index
      [dstoff]. Returns an error message if [srcoff] and [len] do not designate
      a valid range of [src], or if [dstoff] and [len] do not designate a valid
      range of [dst]. *)
end

module Path : sig
  val is_backup_file : string -> bool
  (** [is_backup_file s] returns [true] iff the filename [s]:

      - ends with ['~']
      - or begins with ['#'] and ends with ['#']. *)

  val find_files : names_wo_ext:string list -> Fpath.t list -> Fpath.t list
  (** [find_files ~names_wo_ext files] returns the list of files among [files]
      whose name without extension is equal to an element of [names_wo_ext].
      Backup files are ignored. *)
end

(** Interface to the Unix system. *)
module Unix : sig
  val read_line : ?echo_input:bool -> unit -> string
  (** [read_line ?echo_input ()] reads a line (terminated before a CR) on the
      standard input. If [echo_input] is [true] (by default) input characters
      are echoed on the standard output. *)
end

module Option : sig
  val pp :
    (Format.formatter -> 'a -> unit) -> Format.formatter -> 'a option -> unit

  val equal : ('a -> 'a -> bool) -> 'a option -> 'a option -> bool

  val map : f:('a -> 'b) -> 'a option -> 'b option

  val bind : f:('a -> 'b option) -> 'a option -> 'b option

  val value : default:'a -> 'a option -> 'a

  val to_result : none:'e -> 'a option -> ('a, 'e) result

  module O : sig
    val ( >>= ) : 'a option -> ('a -> 'b option) -> 'b option

    val ( >|= ) : 'a option -> ('a -> 'b) -> 'b option
  end
end

module String : sig
  val pp : Format.formatter -> string -> unit
end

module List : sig
  val pp :
    (Format.formatter -> 'a -> unit) -> Format.formatter -> 'a list -> unit

  val equal : ('a -> 'a -> bool) -> 'a list -> 'a list -> bool

  val filter_map : f:('a -> 'b option) -> 'a list -> 'b list
end

module Result : sig
  module List : sig
    val iter :
      f:('a -> (unit, 'e) Result.result) -> 'a list -> (unit, 'e) Result.result
    (** [iter ~f l] applies [f] on each element of list [l] until an error
        occurs. *)
  end
end
