# Casacore.jl

This package provides Casacore for using in Julia. Casacore does not need to be installed first, as this package makes use of the BinaryBuilder.

This project is in early development and only minimal features are completed yet.

Previous work on Casacore integration has been packaged as [Cassacore.jl](https://github.com/kiranshila/CasaCore.jl) which provides a bespoke C wrapper. This present module differs by using CxxWrap to wrap the C++ methods of Casacore to provide low level access to Casacore internals, and well as a more intuitive high level interface.

## Usage

### Tables

Read-only access to tables and columns:

```
using Casacore.Tables: Table

table = Table("/path/to/my/table.ms")
keys(table)  # => [:UVW, :WEIGHT, :DATA, ...]

uvwcol = table[:UVW]  # <: Column{Float32, 2}
data = uvwcol[:, 1:100]  # Get the first 100 rows
```

A note on performance: whilst the `Column{T, N}` object provides an indexing interface, this is an expensive operation that involves searching and reading from the disk. We do not provide an iterable or AbstractArray interface to this object to discourage its use in this way. Instead, it is recommended to index from a `Column{T, N}` object infrequently, loading large amounts of data at a time, possibly using batching operations to manage memory usage.

For scalar columns and arrays with a fixed size, indexing operations and the resulting array types will be intuitive. For example:

```
flags = table[:FLAG_ROW]  # <: Column{Bool, 1}
size(flags) == (260000,)
flags[:] <: Vector{Bool}

corrected = table[:CORRECTED_DATA]  # <: Column{ComplexF64, 3}
size(corrected) == (4, 768, 260000)
corrected[1:4, 1:192, :] <: Array{ComplexF64, 3}
```

Columns that do not have a fixed size will by typed as providing arrays of arrays. For example:

```
weightcol = table[:WEIGHT]  # <: Column{Vector{Float64}, 1}
size(weightcol) == (260000,)
row = weightcol[2] <: Vector{Float64}
size(row) == (4,)
```

These small array allocations for every row are not great for performance, but are required since we cannot know the size the rows ahead of time.

However, if you _know_ that that your column with no fixed size actually contains constant-sized arrays, you can force Casacore to attempt to load these as one contiguous array:

```
data = weightcol[1:4, :] <: Matrix{Float32}
```

## Still to do

So many things...

* Provide column metadata objects, which can then be used to...
* Create columns
* Provide `setindex!()` on columns to allow writable tables
* Add row functionality
* Measures
