module Tables

export taql

using ..LibCasacore

abstract type ColumnDesc{T, N} end
struct ScalarColumnDesc{T} <: ColumnDesc{T, 0} end
struct ArrayColumnDesc{T <: Array, N} <: ColumnDesc{T, N} end
struct FixedArrayColumnDesc{T, N} <: ColumnDesc{T, N}
    cellsize::NTuple{N, Int}
end

mutable struct Column{T, N, S}
    name::Symbol
    parent::LibCasacore.TableAllocated
    columnref::S
end

function Column(tableref::LibCasacore.Table, name::LibCasacore.String)
    tabledesc= LibCasacore.tableDesc(tableref)
    columndesc = LibCasacore.columnDesc(tabledesc, name)

    scalarT = (LibCasacore.gettype ∘ LibCasacore.dataType)(columndesc)
    ndim = Int(LibCasacore.ndim(columndesc))
    if ndim == 0
        columnref = LibCasacore.ScalarColumn{scalarT}(tableref, name)
    else
        columnref = LibCasacore.ArrayColumn{scalarT}(tableref, name)
    end

    # If fixedshape == True, we treat this as a single multidimensional
    # array::Array{T, ndim + 1} and dimensions (size..., rows).
    # If fixedshape == False we treat this as a vector::Vector{T} of length rows with
    # values that are either scalars (if ndim == 0) or arrays (if ndim > 0).
    fixedshape = Bool(LibCasacore.isFixedShape(columndesc))
    if fixedshape || ndim == 0
        T = scalarT
        N = ndim + 1
    else
        N = 1
        T = Array{scalarT, ndim}
    end

    slice = Tuple(fill(:, N))

    return Column{T, N, typeof(columnref)}(
        Symbol(name), tableref, columnref
    )
end

# Column: implements indexing
function Base.size(c::Column{T, N, S})::NTuple{N, Int} where {T, N, S <: LibCasacore.ArrayColumn}
    return (LibCasacore.shapeColumn(c.columnref)..., LibCasacore.nrow(c.columnref))
end

function Base.size(c::Column{T, 1, S})::NTuple{1, Int} where {T, S <: LibCasacore.ScalarColumn}
    return (LibCasacore.nrow(c.columnref),)
end

Base.length(c::Column) = reduce(*, size(c))

@inline function checkbounds(x::Column{T, N}, I::Vararg{Union{Int, Colon, OrdinalRange}, M}) where {T, N, M}
    if N != M
        throw(DimensionMismatch("Indexing into $(N)-dimensional Column with $(M) indices"))
    end

    Base.checkbounds_indices(Bool, axes(x), I) || throw(BoundsError(x, I))
end

# Required for to_indices() to work
Base.eachindex(::IndexLinear, A::Column) = (@inline; Base.oneto(length(A)))

# Scalar array indexing
function Base.getindex(c::Column{T, 1, S}, i::Union{Int, Colon, OrdinalRange}) where {T, S <: LibCasacore.ScalarColumn}
    @boundscheck checkbounds(c, i)
    i, = to_indices(c, (i,))

    rowslicer = LibCasacore.Slicer(i .- 1)
    arrayslice = LibCasacore.getColumnRange(c.columnref, rowslicer)

    shape = length.(Base.index_shape(i))
    zerodim_as_scalar(LibCasacore.asarray(arrayslice, shape))
end

function Base.setindex!(c::Column{T, 1, S}, v, i::Union{Int, Colon, OrdinalRange}) where {T, S <: LibCasacore.ScalarColumn}
    @boundscheck checkbounds(c, i)
    i, = to_indices(c, (i,))

    varray = collect(T, v)
    Base.setindex_shape_check(varray, length(i))

    GC.@preserve varray begin
        vectorslice = LibCasacore.Vector{T}(
            LibCasacore.IPosition(Tuple(length(i))),
            varray,
            LibCasacore.SHARE
        )
        rowslicer = LibCasacore.Slicer(i .- 1)
        LibCasacore.putColumnRange(c.columnref, rowslicer, vectorslice)
    end

    return v
end

# Array of arrays indexing
function Base.getindex(c::Column{T, 1, S}, i::Int)::T where {T <: Array, S <: LibCasacore.ArrayColumn}
    @boundscheck checkbounds(c, i)
    arrayslice = LibCasacore.getindex(c.columnref, i - 1)
    return LibCasacore.asarray(arrayslice, size(arrayslice))
end

function Base.getindex(c::Column{T, 1, S}, i::Union{Colon, OrdinalRange})::Vector{T} where {T <: Array, S <: LibCasacore.ArrayColumn}
    @boundscheck checkbounds(c, i)
    i, = to_indices(c, (i,))
    return map(i) do i
        @inbounds c[i]
    end
end

function Base.setindex!(c::Column{T, 1, S}, v, i::Int)::T where {T <: Array, S <: LibCasacore.ArrayColumn}
    @boundscheck checkbounds(c, i)

    varray = collect(eltype(T), v)
    GC.@preserve varray begin
        arrayslice = LibCasacore.Array{eltype(T)}(
            LibCasacore.IPosition(size(v)),
            varray,
            LibCasacore.SHARE
        )
        LibCasacore.put(c.columnref, i - 1, arrayslice)
    end
    return v
end

function Base.setindex!(c::Column{T, 1, S}, v, i::Union{Int, Colon, OrdinalRange}) where {T <: Array, S <: LibCasacore.ArrayColumn}
    @boundscheck checkbounds(c, i)
    i, = to_indices(c, (i,))
    for (idx, val) in zip(i, v)
        @inbounds c[idx] = val
    end
    return v
end

# Multidimensional array indexing
function Base.getindex(c::Column{T, N, S}, I::Vararg{Union{Int, Colon, OrdinalRange}, M}) where {T, N, M, S <: LibCasacore.ArrayColumn}
    # We have to do a little extra work if we are forcing a multidim index
    # into an array with no fixed size
    if N == 1 && T <: Array
        Icell, Irow = I[begin:end - 1], I[end]
        @boundscheck checkbounds(c, Irow)

        Irow, = to_indices(c, (Irow,))
        if Colon() in Icell
            throw(ArgumentError("A column with no fixed size cannot be indexed with ':' except along the rows."))
        end

        I =  (Icell..., Irow)
    else
        @boundscheck checkbounds(c, I...)
        I = to_indices(c, I)
    end

    # 0- to 1-based indexing
    I = map(x -> x .- 1, I)
    rowslicer = LibCasacore.Slicer(I[end])
    cellslicer = LibCasacore.Slicer(I[1:(end - 1)]...)

    arrayslice = LibCasacore.getColumnRange(c.columnref, rowslicer, cellslicer)

    shape = length.(Base.index_shape(I...))
    zerodim_as_scalar(LibCasacore.asarray(arrayslice, shape))
end

function Base.setindex!(c::Column{T, N, S}, v, I::Vararg{Union{Int, Colon, OrdinalRange}, M}) where {T, N, M, S <: LibCasacore.ArrayColumn}
    # We have to do a little extra work if we are forcing a multidim index
    # into an array with no fixed size
    if N == 1 && T <: Array
        Icell, Irow = I[begin:end - 1], I[end]
        @boundscheck checkbounds(c, Irow)

        Irow, = to_indices(c, (Irow,))
        if Colon() in Icell
            throw(ArgumentError("A column with no fixed size cannot be indexed with ':' except along the rows."))
        end

        I =  (Icell..., Irow)
    else
        @boundscheck checkbounds(c, I...)
        I = to_indices(c, I)
    end

    varray = collect(eltype(T), v)
    Base.setindex_shape_check(varray, length.(I)...)

    # 1- to 0-based indexing
    I = map(x -> x .- 1, I)
    rowslicer = LibCasacore.Slicer(I[end])
    cellslicer = LibCasacore.Slicer(I[1:(end - 1)]...)

    GC.@preserve varray begin
        arrayslice = LibCasacore.Array{eltype(T)}(
            LibCasacore.IPosition(length.(I)), varray, LibCasacore.SHARE
        )
        LibCasacore.putColumnRange(c.columnref, rowslicer, cellslicer, arrayslice)
    end

    return v
end

struct Table
    tableref::LibCasacore.TableAllocated
end

function Table(path::String; readonly=true)
    path = LibCasacore.String(path)

    tableoption = readonly ? LibCasacore.Old : LibCasacore.Update
    tableref = LibCasacore.Table(path, tableoption)

    return Table(tableref)
end

Base.size(x::Table)::Tuple{Int, Int} = (
    LibCasacore.nrow(x.tableref),
    LibCasacore.ncolumn(LibCasacore.tableDesc(x.tableref))
)

function Base.getindex(x::Table, name::Symbol)
    if name in keys(x)
        return Column(x.tableref, LibCasacore.String(name))
    end
    throw(KeyError(name))
end

function Base.setindex!(x::Table, v::ScalarColumnDesc{T}, name::Symbol) where {T, N}
    if name in keys(x)
        delete!(x, name)
    end
    LibCasacore.addColumn(
        x.tableref,
        LibCasacore.ColumnDesc(
            LibCasacore.ScalarColumnDesc{T}(
                LibCasacore.String(name),
                zero(UInt32)
            )
        ),
        true
    )
    return v
end

function Base.setindex!(x::Table, v::ArrayColumnDesc{T, N}, name::Symbol) where {T, N}
    if name in keys(x)
        delete!(x, name)
    end
    LibCasacore.addColumn(
        x.tableref,
        LibCasacore.ColumnDesc(
            LibCasacore.ArrayColumnDesc{eltype(T)}(
                LibCasacore.String(name),
                N,
                zero(UInt32)
            )
        ),
        true
    )
    return v
end

function Base.setindex!(x::Table, v::FixedArrayColumnDesc{T, N}, name::Symbol) where {T, N}
    if name in keys(x)
        delete!(x, name)
    end
    LibCasacore.addColumn(
        x.tableref,
        LibCasacore.ColumnDesc(
            LibCasacore.ArrayColumnDesc{T}(
                LibCasacore.String(name),
                LibCasacore.IPosition(v.cellsize),
                reinterpret(UInt32, LibCasacore.ColumnFixedShape)
            )
        ),
        true
    )
    return v
end

function Base.delete!(x::Table, name::Symbol)
    if name in keys(x)
        LibCasacore.removeColumn(x.tableref, LibCasacore.String(name))
        return
    end
    throw(KeyError(name))
end

function Base.keys(x::Table)::Vector{Symbol}
    tabledesc = LibCasacore.tableDesc(x.tableref)
    return map(Symbol, LibCasacore.columnNames(tabledesc))
end

function Base.propertynames(x::Table, private::Bool=false)
    subtables = private ? [fieldnames(Table)...] : Symbol[]

    keywords = LibCasacore.keywordSet(x.tableref)
    for i in range(0, LibCasacore.size(keywords) - 1)
        recordid = LibCasacore.RecordFieldId(i)
        if LibCasacore.type(keywords, i) == LibCasacore.TpTable
            push!(subtables, Symbol(LibCasacore.name(keywords, recordid)))
        end
    end

    return tuple(subtables...)
end

function Base.getproperty(x::Table, name::Symbol)
    if hasfield(Table, name)
        return getfield(x, name)
    end

    if name in propertynames(x)
        recordid = LibCasacore.RecordFieldId(LibCasacore.String(name))
        keywords = LibCasacore.keywordSet(x.tableref)
        return Table(LibCasacore.asTable(keywords, recordid))
    end

    return getfield(x, name)
end

flush(x::Table; fsync=true, recursive=true) = LibCasacore.flush(x.tableref, fsync, recursive)

function taql(command::String, table::Table, tables::Vararg{Table})
    tablesvec = LibCasacore.StdVector{LibCasacore.ConstCxxPtr{LibCasacore.Table}}()
    for table in (table, tables...)
        push!(tablesvec, Ref(LibCasacore.ConstCxxPtr(table.tableref)))
    end

    return Table(LibCasacore.tableCommand(
        command,
        tablesvec
    ))
end

function zerodim_as_scalar(x::Array{T, 0}) where T
    return x[]
end

function zerodim_as_scalar(x)
    return x
end

end