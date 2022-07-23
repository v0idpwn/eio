module Family = struct
  type t = [ `INET | `INET6 | `OTHER of int | `UNSPEC ]
end

module Socket_type = struct
  type t = [
    | `STREAM
    | `DGRAM
    | `RAW
    | `OTHER of int
  ]
end

module Addr_Info = struct
  type t = {
    family : Family.t;
    socktype : Socket_type.t;
    protocol : int;
    addr : Net.Sockaddr.t;
    canonname : string option;
  }
end

class virtual t = object
  method virtual getaddrinfo :
    ?family:Family.t ->
    ?protocol:int ->
    ?node:string ->
    ?service:string ->
    unit ->
    Addr_Info.t list
end

let getaddrinfo (dns:t) ?family ?protocol ?node ?service () = dns#getaddrinfo ?family ?protocol ?node ?service ()
