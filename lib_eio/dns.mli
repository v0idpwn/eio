module Family : sig
  type t = [ `INET | `INET6 | `OTHER of int | `UNSPEC ]
end

module Socket_type : sig
  type t = [
    | `STREAM
    | `DGRAM
    | `RAW
    | `OTHER of int
  ]
end

module Addr_Info : sig
  type t = {
    family : Family.t;
    socktype : Socket_type.t;
    protocol : int;
    addr : Net.Sockaddr.t;
    canonname : string option;
  }
end

class virtual t : object
  method virtual getaddrinfo :
    ?family:Family.t ->
    ?protocol:int ->
    ?node:string ->
    ?service:string ->
    unit ->
    Addr_Info.t list
end

val getaddrinfo :
  t ->
  ?family:Family.t ->
  ?protocol:int ->
  ?node:string ->
  ?service:string ->
  unit ->
  Addr_Info.t list
