# erlcapnp

capnproto library in erlang.

Provides ability to generate a .hrl and .erl file for your code, which, with as little code between them and the binary as possible, will let you turn records of the shape #CapnpStruct{field=Value} into valid unpacked capnp messages, and (in future) vice versa. As the only operation on a message right now is to decode it, it does not and cannot support RPC.

The development of this library is largely driven by the needs of my employer, who only needs the encode part, so expect slower development on anything unrelated to this. Use ecapnp if you want something more feature-complete.

Preliminary indications are that the encode speed is more than 10 times as fast as ecapnp (tested 2015-12 on the AddressBook example).

## Comparison to ecapnp

`erlcapnp` doesn't leak processes every time you encode a message. `ecapnp` does and it's unclear how to fix this.

`erlcapnp` doesn't support RPC at all; it regards capnp as a pure serialisation format. Fixing this will require a completely different interface. `ecapnp` supports some basic RPC stuff.

The following benchmarks assume you don't use the capnp types generated by the compiler internally (ie. you have existing code you wish to use with Cap'n'proto) -- actual performance on tightly optimised code will be slightly better. In real usage at Gambit Research, we find a moderate structure composed of mostly list `iodata()` (ie. no `binary()` parts!) and integers (including a struct in a union) totalling around 15 fields takes about 10-20 microseconds to convert to the `erlcapnp` records, and a further 10-20 microseconds to convert to binary form for the wire. The `ecapnp` equivalent code took over a millisecond to do the same.

Serialisation appears to be about 50-150 times faster than the `ecapnp` implementation:

```
Time for {name,bench_erlcapnp_integer_encode}: 0.004354s (0.4354us * 10000)
Time for {name,bench_ecapnp_integer_encode}: 0.34448s (34.448us * 10000)
Time for {name,bench_ecapnp_integer_encode_hotloop_}: 0.216513s (21.6513us * 10000)
```

Serialisating a single struct comes out about 79 times faster. The hotloop variant only creates a single `ecapnp` message, which saves a few micros per loop.

```
Time for {name,bench_erlcapnp_multiple_integer_encode}: 0.004445s (0.4445us * 10000)
Time for {name,bench_ecapnp_multiple_integer_encode}: 0.908042s (90.8042us * 10000)
Time for {name,bench_ecapnp_multiple_integer_encode_hotloop_}: 0.689382s (68.9382us * 10000)
```

Serialising a complex shallow struct is about 200 times faster. The `ecapnp` hotloop fares a bit better at only 155 times faster.

```
Time for {name,bench_erlcapnp_multiple_integer_decode}: 0.009218s (0.9218us * 10000)
Time for {name,bench_ecapnp_multiple_integer_decode}: 0.116732s (11.6732us * 10000)
Time for {name,bench_ecapnp_multiple_integer_decode_singlefield}: 0.03365s (3.365us * 10000)
```

Deserialising same struct is about 13 times faster. If we only ask for one field from `ecapnp`, it's only 2 times faster (there's no such opimisation on `erlcapnp`).

```
Time for {name,bench_erlcapnp_text_encode}: 0.006751s (0.6751us * 10000)
Time for {name,bench_erlcapnp_text_encode}: 0.006081s (0.6081us * 10000)
Time for {name,bench_erlcapnp_text_encode}: 0.007901s (0.7901us * 10000)
Time for {name,bench_erlcapnp_text_encode}: 0.006536s (0.6536us * 10000)
Time for {name,bench_ecapnp_text_encode}: 0.442182s (44.2182us * 10000)
Time for {name,bench_ecapnp_text_encode}: 0.443464s (44.3464us * 10000)
```

`erlcapnp` has a penalty for encoding `iodata()` instead of a pure binary which gets worse with length (the 1st and 3rd test). `ecapnp` only supports binaries and is about 72 times slower than `ecapnp`.

```
Time for {name,bench_erlcapnp_union_group_encode}: 0.014399s (1.4399us * 10000)
Time for {name,bench_erlcapnp_union_group_encode}: 0.013777s (1.3777us * 10000)
Time for {name,bench_erlcapnp_union_group_encode}: 0.007872s (0.7872us * 10000)
Time for {name,bench_ecapnp_union_group_encode}: 0.988411s (98.8411us * 10000)
Time for {name,bench_ecapnp_union_group_encode}: 0.639239s (63.9239us * 10000)
```

`erlcapnp` suffers a bit when encoding unions and lists (first test is a group and a list in a union, second just a list in a union, third is just unions). `ecapnp` also suffers though, getting a slowdown of 72 times on the list-in-union and 81 times on the simpler union test. I was unable to get setting of the anonymous union to a deep type to work in `ecapnp`.

## Types

| capnp | Erlang |
|---|---|
| struct A {} | -record('A', {}). |
| struct B { a @0 :UInt64; } | -record('B', { a :: integer() }). |
| enum EnumType { a @0; b @1; } | -type 'EnumType'() :: a \| b. |
| struct C { a @0 :EnumType; } | -record('C', { a :: 'EnumType'() }). |
| struct D { a @0 :Text; } | -record('D', { a :: iodata() }). |
| struct E { a @0 :Data; } | -record('E', { a :: iodata() }). |
| struct F { a @0 :A; } | -record('F', { a :: #'A'{} }). |
| struct G { a :group { b @0 :B; c @1 :C; } } | -record('G_a', { a :: #'A'{}, b :: #'B'{} }).<br/>-record('G', { a :: #'G_a'{} }). |
| struct H { union { a @0 :A; b @1 :B; } } | -type 'H'() :: { a, #'A'{} } \| { b, #'B'{} } }. |
| struct I { a @0 :UInt64; union { a @0 :A; b @1 :B; } } | -record('I', { a :: integer(), '' :: H() }). |
| struct J { a @0 :UInt64; b :union { a @0 :A; b @1 :B; } } | -record('J', { a :: integer(), b :: H() }). |

Note that pure-anonymous unions are collapsed into their owning scope, as are single-field groups. This behaviour is still in flux, but will be needed if the code is to work safely over hot reloads when data for an old version, generated for an older schema, is in use. (Introduction of a group wrapping a single integer cannot be identified from the schema ordinals.)

## TODO

Very much WIP!

* Namespacing (by prefixing type names?).
* A prettier compile interface (so that capnpc can be used).
* Defaults. Right now defaults on struct and float valued fields are not supported. (Float defaults other than 0.0 are messy; struct is probably impossible to implement at all if the default is recursive, hence scary.)

## NIF branch

Extremely experimental; uses `nif`s to encode exactly one sample message type.

Initial experiments on speed aren't super-encouraging (I do not expect much more than a 2x speedup, if any; it seems like allocating resources is fairly expensive). However, a `nif` implementation will be able to support RPC.

Benchmarks suggest that exposing `nif`s to Erlang to wrap around the capnp functions (initRoot, new MallocMessageBuilder, ...) is quite expensive. The capnp management structures -- builders, message types and so-on must be built onto the heap, and managed by Erlang's garbage collector, meaning many function calls implicity call `enif_alloc` with a penalty of about 200-400 nanoseconds per call. This means a simple "make a new message and set one field" test takes about 3.4 micros, versus the 0.44 micros of `erlcapnp`. I don't think this method will ever win in speed! The `nif` code is still vastly faster than `ecapnp`, however so it may be reasonable way to plug the RPC functionality into Erlang.

On the other hand, there may be some win to making the entire encode step happen in C-space, having a function which mimics the `envelope_capnp` functions in `erlcapnp` and returns either a `MallocMessageBuilder` resource, or a plain `binary()` content of the message. There's still a nasty `malloc` penalty, but some fiddling can result in a function which takes a 7-tuple for `TestMultipleIntegers`, decodes it to plain integers (70 ns), then compiles a `capnp` message (almost free) and turns it to a binary (200 ns -- mostly the allocation of the binary) which it returns. This will probably result in a big win with larger structures.

The likely final form, should there be one, then, is that an optimal `nif`-based solution will look like:
* Encode: have a function to get a `MallocMessageBuilder` which takes an `erlcapnp` structure or reader resource as input. A second function will encode this to a binary/iodata.
* Decode: have a function which returns a reader resource, and a function to turn that into an `erlcapnp` structure, blocking/erroring on incomplete data.

This should give enough flexibility to use any existing `capnp`-based API while enough speed to be able to claim to be faster than the pure Erlang implementation in many/most cases.

## Acknowledgements

A considerable amount of the work for this project was done during working hours for my employer, Gambit Research, as the motivation was to use the code in their systems.

* http://www.gambitresearch.com/
* https://github.com/GambitResearch
