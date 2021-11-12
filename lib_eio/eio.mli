(** Effects based parallel IO for OCaml *)

(** Reporting multiple failures at once. *)
module Multiple_exn : sig
  exception T of exn list
  (** Raised if multiple fibres fail, to report all the exceptions. *)
end

(** Handles for removing callbacks. *)
module Hook : sig
  type t

  val remove : t -> unit
  (** [remove t] removes a previously-added hook.
      If the hook has already been removed, this does nothing. *)

  val null : t
  (** A dummy hook. Removing it does nothing. *)
end

(** {1 Concurrency primitives} *)

(** Commonly used standard features. This module is intended to be [open]ed. *)
module Std : sig

  (** Grouping fibres and other resources. *)
  module Switch : sig
    type t
    (** A switch contains a group of fibres and other resources (such as open file handles).
        Once a switch is turned off, the fibres should cancel themselves.
        A switch is created with [Switch.run fn],
        which does not return until all fibres attached to the switch have finished,
        and all attached resources have been closed.
        Each switch includes its own {!Cancel.t} context. *)

    val run : (t -> 'a) -> 'a
    (** [run fn] runs [fn] with a fresh switch (initially on).
        When [fn] exits, [run] waits for all operations registered with the switch to finish
        (it does not turn the switch off itself).
        If the switch is turned off before it returns, [run] re-raises the switch's exception(s).
        @raise Multiple_exn.T If [turn_off] is called more than once. *)

    val check : t -> unit
    (** [check t] checks that [t] is still on.
        @raise Cancelled If the switch is off. *)

    val get_error : t -> exn option
    (** [get_error t] is like [check t] except that it returns the exception instead of raising it.
        If [t] is finished, this returns (rather than raising) the [Invalid_argument] exception too. *)

    val turn_off : t -> exn -> unit
    (** [turn_off t ex] turns off [t], with reason [ex].
        It returns immediately, without waiting for the shutdown actions to complete.
        If [t] is already off then [ex] is added to the list of exceptions (unless
        [ex] is [Cancelled] or identical to the original exception, in which case
        it is ignored). *)

    val on_release : t -> (unit -> unit) -> unit
    (** [on_release t fn] registers [fn] to be called once [t]'s main function has returned
        and all fibres have finished.
        If [fn] raises an exception, it is passed to [turn_off].
        Release handlers are run in LIFO order, in series.
        If you want to allow other release handlers to run concurrently, you can start the release
        operation and then call [on_release] again from within [fn] to register a function to await the result.
        This will be added to a fresh batch of handlers, run after the original set have finished.
        Note that [fn] is called within a {!Cancel.protect}, since aborting clean-up actions is usually a bad idea
        and the switch may have been cancelled by the time it runs. *)

    val on_release_cancellable : t -> (unit -> unit) -> Hook.t
    (** Like [on_release], but the handler can be removed later. *)

    val add_cancel_hook : t -> (exn -> unit) -> Hook.t
    (** [add_cancel_hook t cancel] registers cancel function [cancel] with [t].
        When [t] is turned off, [cancel] is called.
        This can be used to encourage other fibres to exit.
        If [Switch.run] returns successfully, the hook will not run.
        If [t] is already off, it calls [cancel] immediately. *)
  end

  module Promise : sig
    type !'a t
    (** An ['a t] is a promise for a value of type ['a]. *)

    type 'a u
    (** An ['a u] is a resolver for a promise of type ['a]. *)

    val create : ?label:string -> unit -> 'a t * 'a u
    (** [create ()] is a fresh promise/resolver pair.
        The promise is initially unresolved. *)

    val await : 'a t -> 'a
    (** [await t] blocks until [t] is resolved.
        If [t] is already resolved then this returns immediately.
        If [t] is broken, it raises the exception. *)

    val await_result : 'a t -> ('a, exn) result
    (** [await_result t] is like [await t], but returns [Error ex] if [t] is broken
        instead of raising an exception.
        Note that if the [await_result] itself is cancelled then it still raises. *)

    val fulfill : 'a u -> 'a -> unit
    (** [fulfill u v] successfully resolves [u]'s promise with the value [v].
        Any threads waiting for the result will be added to the run queue. *)

    val break : 'a u -> exn -> unit
    (** [break u ex] resolves [u]'s promise with the exception [ex].
        Any threads waiting for the result will be added to the run queue. *)

    val resolve : 'a t -> ('a, exn) result -> unit
    (** [resolve t (Ok x)] is [fulfill t x] and
        [resolve t (Error ex)] is [break t ex]. *)

    val fulfilled : 'a -> 'a t
    (** [fulfilled x] is a promise that is already fulfilled with result [x]. *)

    val broken : exn -> 'a t
    (** [broken x] is a promise that is already broken with exception [ex]. *)

    type 'a waiters

    type 'a state =
      | Unresolved of 'a waiters
      | Fulfilled of 'a
      | Broken of exn

    val state : 'a t -> 'a state
    (** [state t] is the current state of [t]. *)

    val is_resolved : 'a t -> bool
    (** [is_resolved t] is [true] iff [state t] is [Fulfilled] or [Broken]. *)

    val create_with_id : Ctf.id -> 'a t * 'a u
    (** Like [create], but the caller creates the tracing ID.
        This can be useful when implementing other primitives that use promises internally,
        to give them a different type in the trace output. *)
  end

  module Fibre : sig
    val both : (unit -> unit) -> (unit -> unit) -> unit
    (** [both f g] runs [f ()] and [g ()] concurrently.
        They run in a new cancellation sub-context, and
        if either raises an exception, the other is cancelled.
        [both] waits for both functions to finish even if one raises
        (it will then re-raise the original exception).
        @raise Multiple_exn.T if both fibres raise exceptions (excluding {!Cancel.Cancelled}). *)

    val first : (unit -> 'a) -> (unit -> 'a) -> 'a
    (** [first f g] runs [f ()] and [g ()] concurrently.
        They run in a new cancellation sub-context, and when one finishes the other is cancelled.
        If one raises, the other is cancelled and the exception is reported.
        @raise Multiple_exn.T if both fibres raise exceptions (excluding {!Cancel.Cancelled} when cancelled). *)

    val fork_ignore : sw:Switch.t -> (unit -> unit) -> unit
    (** [fork_ignore ~sw fn] runs [fn ()] in a new fibre, but does not wait for it to complete.
        The new fibre is attached to [sw] (which can't finish until the fibre ends).
        The new fibre inherits [sw]'s cancellation context.
        If the fibre raises an exception, [sw] is turned off.
        If [sw] is already off then [fn] fails immediately, but the calling thread continues. *)

    val fork_sub_ignore : ?on_release:(unit -> unit) -> sw:Switch.t -> on_error:(exn -> unit) -> (Switch.t -> unit) -> unit
    (** [fork_sub_ignore ~sw ~on_error fn] is like [fork_ignore], but it creates a new sub-switch for the fibre.
        This means that you can cancel the child switch without cancelling the parent.
        This is a convenience function for running {!Switch.run} inside a {!fork_ignore}.
        @param on_release If given, this function is called when the new fibre ends.
                          If the fibre cannot be created (e.g. because [sw] is already off), it runs immediately.
        @param on_error This is called if the fibre raises an exception (other than {!Cancel.Cancelled}).
                        If it raises in turn, the parent switch is turned off. *)

    val fork : sw:Switch.t -> exn_turn_off:bool -> (unit -> 'a) -> 'a Promise.t
    (** [fork ~sw ~exn_turn_off fn] starts running [fn ()] in a new fibre and returns a promise for its result.
        The new fibre is attached to [sw] (which can't finish until the fibre ends).
        @param exn_turn_off If [true] and [fn] raises an exception, [sw] is turned off (in addition to breaking the promise). *)

    val yield : unit -> unit
    (** [yield ()] asks the scheduler to switch to the next runnable task.
        The current task remains runnable, but goes to the back of the queue. *)
  end

  val traceln :
    ?__POS__:string * int * int * int ->
    ('a, Format.formatter, unit, unit) format4 -> 'a
  (** [traceln fmt] outputs a debug message (typically to stderr).
      Trace messages are printed by default and do not require logging to be configured first.
      The message is printed with a newline, and is flushed automatically.
      [traceln] is intended for quick debugging rather than for production code.

      Unlike most Eio operations, [traceln] will never switch to another fibre;
      if the OS is not ready to accept the message then the whole domain waits.

      It is safe to call [traceln] from multiple domains at the same time.
      Each line will be written atomically.

      Examples:
      {[
        traceln "x = %d" x;
        traceln "x = %d" x ~__POSS__;   (* With location information *)
      ]}
      @param __POS__ Display [__POS__] as the location of the [traceln] call. *)
end

open Std

(** A counting semaphore for use within a single domain.
    The API is based on OCaml's [Semaphore.Counting]. *)
module Semaphore : sig
  type t
  (** The type of counting semaphores. *)

  val make : int -> t
  (** [make n] returns a new counting semaphore, with initial value [n].
      The initial value [n] must be nonnegative.
      @raise Invalid_argument if [n < 0] *)

  val release : t -> unit
  (** [release t] increments the value of semaphore [t].
      If other fibres are waiting on [t], the one that has been waiting the longest is resumed.
      @raise Sys_error if the value of the semaphore would overflow [max_int] *)

  val acquire : t -> unit
  (** [acquire t] blocks the calling fibre until the value of semaphore [t]
      is not zero, then atomically decrements the value of [t] and returns. *)

  val get_value : t -> int
  (** [get_value t] returns the current value of semaphore [t]. *)
end

(** A stream/queue. *)
module Stream : sig
  type 'a t
  (** A queue of items of type ['a]. *)

  val create : int -> 'a t
  (** [create capacity] is a new stream which can hold up to [capacity] items without blocking writers.
      If [capacity = 0] then writes block until a reader is ready. *)

  val add : 'a t -> 'a -> unit
  (** [add t item] adds [item] to [t].
      If this would take [t] over capacity, it blocks until there is space. *)

  val take : 'a t -> 'a
  (** [take t] takes the next item from the head of [t].
      If no items are available, it waits until one becomes available. *)
end  

(** Cancelling other fibres when an exception occurs. *)
module Cancel : sig
  (** This is the low-level interface to cancellation.
      Every {!Switch} includes a cancellation context and most users will just use that API instead. *)

  type t
  (** A cancellation context. *)

  exception Cancelled of exn
  (** [Cancelled ex] indicates that the context was cancelled with exception [ex].
      It is usually not necessary to report a [Cancelled] exception to the user,
      as the original problem will be handled elsewhere. *)

  exception Cancel_hook_failed of exn list
  (** Raised by {!cancel} if any of the cancellation hooks themselves fail. *)

  val sub : (t -> 'a) -> 'a
  (** [sub fn] installs a new cancellation context [t], runs [fn t] inside it, and then restores the old context.
      If the old context is cancelled while [fn] is running then [t] is cancelled too.
      [t] cannot be used after [sub] returns. *)

  val protect : (unit -> 'a) -> 'a
  (** [protect fn] runs [fn] in a new cancellation context that isn't cancelled when its parent is.
      This can be used to clean up resources on cancellation.
      However, it is usually better to use {!Switch.on_release} (which calls this for you). *)

  val protect_full : (t -> 'a) -> 'a
  (** [protect_full fn] is like {!protect}, but also gives access to the new context. *)

  val check : t -> unit
  (** [check t] checks that [t] hasn't been cancelled.
      @raise Cancelled If the context has been cancelled. *)

  val get_error : t -> exn option
  (** [get_error t] is like [check t] except that it returns the exception instead of raising it.
      If [t] is finished, this returns (rather than raising) the [Invalid_argument] exception too. *)

  val add_hook : t -> (exn -> unit) -> Hook.t
  (** [add_hook t fn] registers cancellation function [fn] with [t].
      When [t] is cancelled, [protect (fun () -> fn ex)] is called.
      If [t] is already cancelled, it calls [fn] immediately. *)

  val cancel : t -> exn -> unit
  (** [cancel t ex] marks [t] as cancelled and then calls all registered hooks,
      passing [ex] as the argument.
      All hooks are run, even if some of them raise exceptions.
      @raise Cancel_hook_failed if one or more hooks fail. *)
end

(** {1 Cross-platform OS API} *)

(** A base class for objects that can be queried at runtime for extra features. *)
module Generic : sig
  type 'a ty = ..
  (** An ['a ty] is a query for a feature of type ['a]. *)

  class type t = object
    method probe : 'a. 'a ty -> 'a option
  end

  val probe : #t -> 'a ty -> 'a option
end

(** Byte streams. *)
module Flow : sig
  type shutdown_command = [ `Receive | `Send | `All ]

  type read_method = ..
  (** Sources can offer a list of ways to read them, in order of preference. *)

  type read_method += Read_source_buffer of ((Cstruct.t list -> unit) -> unit)
  (** If a source offers [Read_source_buffer rsb] then the user can call [rsb fn]
      to borrow a view of the source's buffers.
      [rb] will raise [End_of_file] if no more data will be produced.
      If no data is currently available, [rb] will wait for some to become available before calling [fn]
      (turning off [sw] will abort the operation).
      [fn] must not continue to use the buffers after it returns. *)

  class type close = object
    method close : unit
  end

  val close : #close -> unit

  class virtual read : object
    method virtual read_methods : read_method list
    method virtual read_into : Cstruct.t -> int
  end

  val read_into : #read -> Cstruct.t -> int
  (** [read_into reader buf] reads one or more bytes into [buf].
      It returns the number of bytes written (which may be less than the
      buffer size even if there is more data to be read).
      [buf] must not be zero-length.
      @raise End_of_file if there is no more data to read *)

  val read_methods : #read -> read_method list
  (** [read_methods flow] is a list of extra ways of reading from [flow],
      with the preferred (most efficient) methods first.
      If no method is suitable, {!read_into} should be used as the fallback. *)

  (** Producer base class. *)
  class virtual source : object
    inherit Generic.t
    inherit read
  end

  val string_source : string -> source

  val cstruct_source : Cstruct.t list -> source

  class virtual write : object
    method virtual write : 'a. (#source as 'a) -> unit
  end

  val copy : #source -> #write -> unit
  (** [copy src dst] copies data from [src] to [dst] until end-of-file. *)

  val copy_string : string -> #write -> unit

  (** Consumer base class. *)
  class virtual sink : object
    inherit Generic.t
    inherit write
  end

  val buffer_sink : Buffer.t -> sink

  (** Bidirectional stream base class. *)
  class virtual two_way : object
    inherit Generic.t
    inherit read
    inherit write

    method virtual shutdown : shutdown_command -> unit
  end

  val shutdown : #two_way -> shutdown_command -> unit
end

module Net : sig
  exception Connection_reset of exn

  module Sockaddr : sig
    type inet_addr = Unix.inet_addr

    type t = [
      | `Unix of string
      | `Tcp of inet_addr * int
    ]

    val pp : Format.formatter -> t -> unit
  end

  class virtual listening_socket : object
    method virtual close : unit
    method virtual accept_sub :
      sw:Switch.t ->
      on_error:(exn -> unit) ->
      (sw:Switch.t -> <Flow.two_way; Flow.close> -> Sockaddr.t -> unit) ->
      unit
  end

  val accept_sub :
    sw:Switch.t ->
    #listening_socket ->
    on_error:(exn -> unit) ->
    (sw:Switch.t -> <Flow.two_way; Flow.close> -> Sockaddr.t -> unit) ->
    unit
  (** [accept socket fn] waits for a new connection to [socket] and then runs [fn ~sw flow client_addr] in a new fibre,
      created with [Fibre.fork_sub_ignore].
      [flow] will be closed automatically when the sub-switch is finished, if not already closed by then. *)

  class virtual t : object
    method virtual listen : reuse_addr:bool -> backlog:int -> sw:Switch.t -> Sockaddr.t -> listening_socket
    method virtual connect : sw:Switch.t -> Sockaddr.t -> <Flow.two_way; Flow.close>
  end

  val listen : ?reuse_addr:bool -> backlog:int -> sw:Switch.t -> #t -> Sockaddr.t -> listening_socket
  (** [listen ~sw ~backlog t addr] is a new listening socket bound to local address [addr].
      The new socket will be closed when [sw] finishes, unless closed manually first.
      For (non-abstract) Unix domain sockets, the path will be removed afterwards.
      @param backlog The number of pending connections that can be queued up (see listen(2)).
      @param reuse_addr Set the [Unix.SO_REUSEADDR] socket option.
                        For Unix paths, also remove any stale left-over socket. *)

  val connect : sw:Switch.t -> #t -> Sockaddr.t -> <Flow.two_way; Flow.close>
  (** [connect ~sw t addr] is a new socket connected to remote address [addr].
      The new socket will be closed when [sw] finishes, unless closed manually first. *)
end

module Domain_manager : sig
  class virtual t : object
    method virtual run_compute_unsafe : 'a. (unit -> 'a) -> 'a
  end

  val run_compute_unsafe : #t -> (unit -> 'a) -> 'a
  (** [run_compute_unsafe t f] runs [f ()] in a newly-created domain and returns the result.
      The new domain does not get an event loop, and so cannot perform IO, fork fibres, etc.
      Other fibres in the calling domain can run in parallel with the new domain.
      Unsafe because [f] must only be able to access thread-safe values from the
      calling domain, but this is not enforced by the type system. *)
end

module Time : sig
  class virtual clock : object
    method virtual now : float
    method virtual sleep_until : float -> unit
  end

  val now : #clock -> float
  (** [now t] is the current time according to [t]. *)

  val sleep_until : #clock -> float -> unit
  (** [sleep_until t time] waits until the given time is reached. *)

  val sleep : #clock -> float -> unit
  (** [sleep t d] waits for [d] seconds. *)
end

module Dir : sig
  type path = string

  exception Already_exists of path * exn
  exception Not_found of path * exn
  exception Permission_denied of path * exn

  class virtual rw : object
    inherit Generic.t
    inherit Flow.read
    inherit Flow.write
  end

  type create = [`Never | `If_missing of Unix.file_perm | `Or_truncate of Unix.file_perm | `Exclusive of Unix.file_perm]
  (** When to create a new file:
      If [`Never] then it's an error if the named file doesn't exist.
      If [`If_missing] then an existing file is simply opened.
      If [`Or_truncate] then an existing file truncated to zero length.
      If [`Exclusive] then it is an error is the file does exist.
      If a new file is created, the given permissions are used for it. *)

  (** A [Dir.t] represents access to a directory and contents, recursively. *)
  class virtual t : object
    method virtual open_in : sw:Switch.t -> path -> <Flow.source; Flow.close>
    method virtual open_out :
      sw:Switch.t ->
      append:bool ->
      create:create ->
      path -> <rw; Flow.close>
    method virtual mkdir : perm:Unix.file_perm -> path -> unit
    method virtual open_dir : sw:Switch.t -> path -> t_with_close
  end
  and virtual t_with_close : object
    inherit t
    method virtual close : unit
  end

  val open_in : sw:Switch.t -> #t -> path -> <Flow.source; Flow.close>
  (** [open_in ~sw t path] opens [t/path] for reading.
      Note: files are always opened in binary mode. *)

  val with_open_in : #t -> path -> (<Flow.source; Flow.close> -> 'a) -> 'a
  (** [with_open_in] is like [open_in], but calls [fn flow] with the new flow and closes
      it automatically when [fn] returns (if it hasn't already been closed by then). *)

  val open_out :
    sw:Switch.t ->
    ?append:bool ->
    create:create ->
    #t -> path -> <rw; Flow.close>
  (** [open_out ~sw t path] opens [t/path] for reading and writing.
      Note: files are always opened in binary mode.
      @param append Open for appending: always write at end of file.
      @param create Controls whether to create the file, and what permissions to give it if so. *)

  val with_open_out :
    ?append:bool ->
    create:create ->
    #t -> path -> (<rw; Flow.close> -> 'a) -> 'a
  (** [with_open_out] is like [open_out], but calls [fn flow] with the new flow and closes
      it automatically when [fn] returns (if it hasn't already been closed by then). *)

  val mkdir : #t -> perm:Unix.file_perm -> path -> unit
  (** [mkdir t ~perm path] creates a new directory [t/path] with permissions [perm]. *)

  val open_dir : sw:Switch.t -> #t -> path -> <t; Flow.close>
  (** [open_dir ~sw t path] opens [t/path].
      This can be passed to functions to grant access only to the subtree [t/path]. *)

  val with_open_dir : #t -> path -> (<t; Flow.close> -> 'a) -> 'a
  (** [with_open_dir] is like [open_dir], but calls [fn dir] with the new directory and closes
      it automatically when [fn] returns (if it hasn't already been closed by then). *)
end

(** The standard environment of a process. *)
module Stdenv : sig
  type t = <
    stdin  : Flow.source;
    stdout : Flow.sink;
    stderr : Flow.sink;
    net : Net.t;
    domain_mgr : Domain_manager.t;
    clock : Time.clock;
    fs : Dir.t;
    cwd : Dir.t;
  >

  val stdin  : <stdin  : #Flow.source as 'a; ..> -> 'a
  val stdout : <stdout : #Flow.sink   as 'a; ..> -> 'a
  val stderr : <stderr : #Flow.sink   as 'a; ..> -> 'a

  val net : <net : #Net.t as 'a; ..> -> 'a
  val domain_mgr : <domain_mgr : #Domain_manager.t as 'a; ..> -> 'a
  val clock : <clock : #Time.clock as 'a; ..> -> 'a

  val cwd : <cwd : #Dir.t as 'a; ..> -> 'a
  (** [cwd t] is the current working directory of the process (this may change
      over time if the process does a `chdir` operation, which is not recommended). *)

  val fs : <fs : #Dir.t as 'a; ..> -> 'a
  (** [fs t] is the process's full access to the filesystem.
      Paths can be absolute or relative (to the current working directory).
      Using relative paths with this is similar to using them with {!cwd},
      except that this will follow symlinks to other parts of the filesystem.
      [fs] is useful for handling paths passed in by the user. *)
end

(** {1 Provider API for OS schedulers} *)

(** API for use by the scheduler implementation. *)
module Private : sig
  type context = {
    tid : Ctf.id;
    mutable cancel : Cancel.t;
  }

  module Effects : sig
    open EffectHandlers

    type 'a enqueue = ('a, exn) result -> unit
    (** A function provided by the scheduler to reschedule a previously-suspended thread. *)

    type _ eff += 
      | Suspend : (context -> 'a enqueue -> unit) -> 'a eff
      (** [Suspend fn] is performed when a fibre must be suspended
          (e.g. because it called {!Promise.await} on an unresolved promise).
          The effect handler runs [fn fibre enqueue] in the scheduler context,
          passing it the suspended fibre's context and a function to resume it.
          [fn] should arrange for [enqueue] to be called once the thread is ready to run again. *)

      | Fork : (unit -> 'a) -> 'a Promise.t eff
      (** See {!Fibre.fork} *)

      | Fork_ignore : (unit -> unit) -> unit eff
      (** See {!Fibre.fork_ignore} *)

      | Trace : (?__POS__:(string * int * int * int) -> ('a, Format.formatter, unit, unit) format4 -> 'a) eff
      (** [perform Trace fmt] writes trace logging to the configured trace output.
          It must not switch fibres, as tracing must not affect scheduling.
          If the system is not ready to receive the trace output,
          the whole domain must block until it is. *)

      | Set_cancel : Cancel.t -> Cancel.t eff
      (** [Set_cancel c] sets the running fibre's cancel context to [c] and returns the previous context. *)
  end

  val boot_cancel : Cancel.t
  (** A dummy context which is useful briefly during start up before the backend calls {!Cancel.protect}
      to install a proper context. *)
end
