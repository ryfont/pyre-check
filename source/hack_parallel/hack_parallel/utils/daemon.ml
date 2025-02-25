(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(* TODO(T132410158) Add a module-level doc comment. *)


type 'a in_channel = Timeout.in_channel
type 'a out_channel = Pervasives.out_channel

type ('in_, 'out) channel_pair = 'in_ in_channel * 'out out_channel

type ('in_, 'out) handle = {
  channels : ('in_, 'out) channel_pair;
  pid : int;
}

(* Windows: ensure that the serialize/deserialize functions
   for the custom block of "Unix.file_descr" are registred. *)
let () = Lazy.force Handle.init

let to_channel :
  'a out_channel -> ?flags:Marshal.extern_flags list -> ?flush:bool ->
  'a -> unit =
  fun oc ?(flags = []) ?flush:(should_flush=true) v ->
  Marshal.to_channel oc v flags;
  if should_flush then flush oc

let from_channel : ?timeout:Timeout.t -> 'a in_channel -> 'a = fun ?timeout ic ->
  Timeout.input_value ?timeout ic

let flush : 'a out_channel -> unit = Pervasives.flush

let descr_of_in_channel : 'a in_channel -> Unix.file_descr =
  Timeout.descr_of_in_channel

let descr_of_out_channel : 'a out_channel -> Unix.file_descr =
  Unix.descr_of_out_channel

let cast_in ic = ic
let cast_out oc = oc

(* We cannot fork() on Windows, so in order to emulate this in a
 * cross-platform way, we use create_process() and set the HH_SERVER_DAEMON
 * environment variable to indicate which function the child should
 * execute. On Unix, create_process() does fork + exec, so global state is
 * not copied; in particular, if you have set a mutable reference the
 * daemon will not see it. All state must be explicitly passed via
 * environment variables; see set/get_context() below.
 *
 * With some factoring we could make the daemons into separate binaries
 * altogether and dispense with this emulation. *)

module Entry : sig

  (* All the 'untyped' operations---that are required for the
     entry-points hashtable and the parameters stored in env
     variable---are hidden in this sub-module, behind a 'type-safe'
     interface. *)

  type ('param, 'input, 'output) t
  val register:
    string -> ('param -> ('input, 'output) channel_pair -> unit) ->
    ('param, 'input, 'output) t
  val find:
    ('param, 'input, 'output) t ->
    'param ->
    ('input, 'output) channel_pair -> unit
  val set_context:
    ('param, 'input, 'output) t -> 'param ->
    Unix.file_descr * Unix.file_descr ->
    unit
  val get_context:
    unit ->
    (('param, 'input, 'output) t * 'param * ('input, 'output) channel_pair)
  val clear_context:
    unit -> unit

end = struct

  type ('param, 'input, 'output) t = string

  (* Store functions as 'Obj.t' *)
  let entry_points : (string, Obj.t) Hashtbl.t = Hashtbl.create 23
  let register name f =
    if Hashtbl.mem entry_points name then
      Printf.ksprintf failwith
        "Daemon.register_entry_point: duplicate entry point %S."
        name;
    Hashtbl.add entry_points name (Obj.repr f);
    name

  let find name =
    try Obj.obj (Hashtbl.find entry_points name)
    with Not_found ->
      Printf.ksprintf failwith
        "Unknown entry point %S" name

  let set_context entry param (ic, oc) =
    let data = (ic, oc, param) in
    Unix.putenv "HH_SERVER_DAEMON" entry;
    let file, oc =
      Filename.open_temp_file
        ~mode:[Open_binary]
        ~temp_dir:Sys_utils.temp_dir_name
        "daemon_param" ".bin" in
    output_value oc data;
    close_out oc;
    Unix.putenv "HH_SERVER_DAEMON_PARAM" file

  (* How this works on Unix: It may appear like we are passing file descriptors
   * from one process to another here, but in_handle / out_handle are actually
   * file descriptors that are already open in the current process -- they were
   * created by the parent process before it did fork + exec. However, since
   * exec causes the child to "forget" everything, we have to pass the numbers
   * of these file descriptors as arguments.
   *
   * I'm not entirely sure what this does on Windows. *)
  let get_context () =
    let entry = Unix.getenv "HH_SERVER_DAEMON" in
    if entry = "" then raise Not_found;
    let (in_handle, out_handle, param) =
      try
        let file = Sys.getenv "HH_SERVER_DAEMON_PARAM" in
        if file = "" then raise Not_found;
        let ic = Sys_utils.open_in_bin_no_fail file in
        let res = Marshal.from_channel ic in
        Sys_utils.close_in_no_fail "Daemon.get_context" ic;
        Sys.remove file;
        res
      with _exn ->
        failwith "Can't find daemon parameters." in
    (entry, param,
     (Timeout.in_channel_of_descr in_handle,
      Unix.out_channel_of_descr out_handle))

  let clear_context () =
    Unix.putenv "HH_SERVER_DAEMON" "";
    Unix.putenv "HH_SERVER_DAEMON_PARAM" "";

end

type ('param, 'input, 'output) entry = ('param, 'input, 'output) Entry.t

let exec entry param ic oc =
  let f = Entry.find entry in
  try f param (ic, oc); exit 0
  with e ->
    prerr_endline (Printexc.to_string e);
    Printexc.print_backtrace stderr;
    exit 2

let register_entry_point = Entry.register

let fd_of_path path =
  Sys_utils.with_umask 0o111 begin fun () ->
    Sys_utils.mkdir_no_fail (Filename.dirname path);
    Unix.openfile path [Unix.O_RDWR; Unix.O_CREAT; Unix.O_TRUNC] 0o666
  end

let null_fd () = fd_of_path Sys_utils.null_path

let setup_channels channel_mode =
  match channel_mode with
  | `pipe ->
      let parent_in, child_out = Unix.pipe () in
      let child_in, parent_out = Unix.pipe () in
      (* Close descriptors on exec so they are not leaked. *)
      Unix.set_close_on_exec parent_in;
      Unix.set_close_on_exec parent_out;
      (parent_in, child_out), (child_in, parent_out)
  | `socket ->
      let parent_fd, child_fd = Unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
      (* FD's on sockets are bi-directional. *)
      (parent_fd, child_fd), (child_fd, parent_fd)

let make_pipe (descr_in, descr_out)  =
  let ic = Timeout.in_channel_of_descr descr_in in
  let oc = Unix.out_channel_of_descr descr_out in
  ic, oc

let close_pipe channel_mode (ch_in, ch_out) =
  match channel_mode with
  | `pipe ->
      Timeout.close_in ch_in;
      close_out ch_out
  | `socket ->
      (* the in and out FD's are the same. Close only once. *)
      Timeout.close_in ch_in

(* This only works on Unix, and should be avoided as far as possible. Use
 * Daemon.spawn instead. *)
let fork
    ?(channel_mode = `pipe)
    (type param)
    (log_stdout, log_stderr) (f : param -> ('a, 'b) channel_pair -> unit)
    (param : param) : ('b, 'a) handle =
  let (parent_in, child_out), (child_in, parent_out)
    = setup_channels channel_mode in
  let (parent_in, child_out) = make_pipe (parent_in, child_out) in
  let (child_in, parent_out) = make_pipe (child_in, parent_out) in
  match Fork.fork () with
  | -1 -> failwith "Go get yourself a real computer"
  | 0 -> (* child *)
      (try
         ignore(Unix.setsid());
         close_pipe channel_mode (parent_in, parent_out);
         Sys_utils.with_umask 0o111 begin fun () ->
           let fd = null_fd () in
           Unix.dup2 fd Unix.stdin;
           Unix.close fd;
         end;
         Unix.dup2 log_stdout Unix.stdout;
         Unix.dup2 log_stderr Unix.stderr;
         if log_stdout <> Unix.stdout then Unix.close log_stdout;
         if log_stderr <> Unix.stderr && log_stderr <> log_stdout then
           Unix.close log_stderr;
         f param (child_in, child_out);
         exit 0
       with e ->
         prerr_endline (Printexc.to_string e);
         Printexc.print_backtrace stderr;
         exit 1)
  | pid -> (* parent *)
      close_pipe channel_mode (child_in, child_out);
      { channels = parent_in, parent_out; pid }

let spawn
    (type param) (type input) (type output)
    ?(channel_mode = `pipe)
    (stdin, stdout, stderr)
    (entry: (param, input, output) entry)
    (param: param) : (output, input) handle =
  let (parent_in, child_out), (child_in, parent_out) =
    setup_channels channel_mode in
  Entry.set_context entry param (child_in, child_out);
  let exe = Sys_utils.executable_path () in
  let pid = Unix.create_process exe [|exe|] stdin stdout stderr in
  Entry.clear_context ();
  (match channel_mode with
   | `pipe ->
       Unix.close child_in;
       Unix.close child_out;
   | `socket ->
       (* the in and out FD's are the same. Close only once. *)
       Unix.close child_in);
  if stdin <> Unix.stdin then Unix.close stdin;
  if stdout <> Unix.stdout then Unix.close stdout;
  if stderr <> Unix.stderr && stderr <> stdout then
    Unix.close stderr;
  { channels = Timeout.in_channel_of_descr parent_in,
               Unix.out_channel_of_descr parent_out;
    pid }

(* for testing code *)
let devnull () =
  let ic = Timeout.open_in "/dev/null" in
  let oc = open_out "/dev/null" in
  {channels = ic, oc; pid = 0}

(**
 * In order for the Daemon infrastructure to work, the beginning of your
 * program (or very close to the beginning) must start with a call to
 * check_entry_point.
 *
 * Details: Daemon.spawn essentially does a fork then exec of the currently
 * running program. Thus, the child process will just end up running the exact
 * same program as the parent if you forgot to start with a check_entry_point.
 * The parent process sees this as a NOOP when its program starts, but a
 * child process (from Daemon.spawn) will use this as a GOTO to its entry
 * point.
*)
let check_entry_point () =
  try
    let entry, param, (ic, oc) = Entry.get_context () in
    Entry.clear_context ();
    exec entry param ic oc
  with Not_found -> ()

let close { channels = (ic, oc); _ } =
  Timeout.close_in ic;
  close_out oc

let kill h =
  close h;
  Sys_utils.terminate_process h.pid

let kill_and_wait h =
  kill h;
  let rec ensure_waitpid pid =
    (* `waitpid` may be interrupted by other signals. 
     * When this happens, we will get an EINTR error in which case the wait
     * operation needs to be retried.
     * For some reason, the EINTR issue happens more frequently on MacOS than
     * on Linux... *)
    try
      Unix.waitpid [] pid |> ignore
    with Unix.Unix_error (Unix.EINTR, _, _) ->
      ensure_waitpid pid
  in
  ensure_waitpid h.pid

let close_out = close_out
let output_string = output_string
let flush = flush

let close_in = Timeout.close_in
let input_char ic = Timeout.input_char ic
let input_value ic = Timeout.input_value ic
