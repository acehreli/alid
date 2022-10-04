# Introduction

This repository is a collection of D modules written by Ali Çehreli.

## Name

The package name `alid` is a combination of "Ali" and "D".

# History

It started with `cached` which was based on [an old idea of
Ali's](https://forum.dlang.org/post/ifg5ei$2qc7$1@digitalmars.com) that rested
for more than ten years. Ali decided to revisit the idea when a piece of D
code--written by Janis, a friend and colleague--produced surprising results. The
surprises were due to side effects in a generator function similar to the `map`
lambda in the following code:

```D
    auto r = iota(n)
             .map!((i) {
                     arr ~= i;     // <-- A side effect (adds to an array)
                     return i;
                 })
             .filter!(i => true);  // <-- The side effect is repeated
```

Every access to the generated "element" down the execution chain repeats the
side effect, adding one more element to the array in the code above.

# Features

## `cached`

`cached` is for executing elements only *once* while not holding on to old
elements for too long; the elements that have been `popFront`ed by all ranges
are dropped from the cache according some heuristics.

`cached` was the main topic of [Ali's DConf 2022 lightning
talk](https://youtu.be/ksNGwLTe0Ps?t=20367).

It caches the elements of its source range to ensure that the side effect of
each generated element is applied only once:

```D
    auto r = iota(n)
             .map!((i) {
                     arr ~= i;     // <-- A side effect (adds to an array)
                     return i;
                 })
             .cached               // <-- Caches the generated elements
             .filter!(i => true);  // <-- The side effect is NOT repeated
```

`cached` provides a `ForwardRange` interface as well as random access to
elements even when the source range is an `InputRange`.

## `circularblocks`

`circularblocks` was written for storing range elements of `cached`. It can be
used independently.


## `blockreusable`

`blockreusable` was written as storage blocks for `circularblocks`. It can be
used independently.

## `errornogc`

`errornogc` was needed for throwing `Error`s from `@nogc` code. It can be used
independently.

## `test`

`test` contains some helper utilities for unit testing.
