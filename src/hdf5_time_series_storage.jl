
import HDF5

const HDF5_TS_ROOT_PATH = "time_series"

"""
Stores all time series data in an HDF5 file.

The file used is assumed to be temporary and will be automatically deleted when there are
no more references to the storage object.
"""
mutable struct Hdf5TimeSeriesStorage <: TimeSeriesStorage
    file_path::String
    read_only::Bool
end

"""
Constructs Hdf5TimeSeriesStorage by creating a temp file.
"""
function Hdf5TimeSeriesStorage()
    return Hdf5TimeSeriesStorage(true)
end

"""
Constructs Hdf5TimeSeriesStorage.

# Arguments
- `create_file::Bool`: create new file
- `filename=nothing`: if nothing, create a temp file, else use this name.
- `directory=nothing`: if set and filename is nothing, create a temp file in this
   directory. Use tempdir() if not set. This should be set if the time series data is larger
   than the tmp filesystem can hold.
- `read_only = false`: If true, don't allow changes to the file. Allows simultaneous read
   access.
"""
function Hdf5TimeSeriesStorage(
    create_file::Bool;
    filename = nothing,
    directory = nothing,
    read_only = false,
)
    if create_file
        if isnothing(filename)
            if isnothing(directory)
                directory = tempdir()
            end
            filename, io = mktemp(directory)
            close(io)
        end

        storage = Hdf5TimeSeriesStorage(filename, read_only)
        _make_file(storage)
    else
        storage = Hdf5TimeSeriesStorage(filename, read_only)
    end

    @debug "Constructed new Hdf5TimeSeriesStorage" storage.file_path read_only

    return storage
end

"""
Constructs Hdf5TimeSeriesStorage from an existing file.
"""
function from_file(
    ::Type{Hdf5TimeSeriesStorage},
    filename::AbstractString;
    read_only = false,
    directory = nothing,
)
    if !isfile(filename)
        error("time series storage $filename does not exist")
    end

    if read_only
        file_path = abspath(filename)
    else
        parent = isnothing(directory) ? tempdir() : directory
        file_path, io = mktemp(parent)
        close(io)
        copy_file(filename, file_path)
    end
    storage = Hdf5TimeSeriesStorage(false; filename = file_path, read_only = read_only)
    @info "Loaded time series from storage file existing=$filename new=$(storage.file_path)"
    return storage
end

get_file_path(storage::Hdf5TimeSeriesStorage) = storage.file_path

function serialize_time_series!(
    storage::Hdf5TimeSeriesStorage,
    component_uuid::UUIDs.UUID,
    name::AbstractString,
    ts::TimeSeriesData,
)
    check_read_only(storage)
    uuid = string(get_uuid(ts))
    component_name = make_component_name(component_uuid, name)

    HDF5.h5open(storage.file_path, "r+") do file
        root = _get_root(storage, file)
        if !haskey(root, uuid)
            HDF5.create_group(root, uuid)
            path = root[uuid]
            data = get_array_for_hdf(ts)
            path["data"] = data
            _write_time_series_attributes!(storage, ts, path)
            path["components"] = [component_name]
            @debug "Create new time series entry." uuid component_uuid name
        else
            path = root[uuid]
            @debug "Add reference to existing time series entry." uuid component_uuid name
            _append_item!(path, "components", component_name)
        end
    end

    return
end

"""
Return a String for the data type of the forecast data, this implementation avoids the use of `eval` on arbitrary code stored in HDF dataset.
"""
function get_data_type(ts::TimeSeriesData)
    data_type = eltype_data(ts)
    if data_type <: CONSTANT
        return "CONSTANT"
    elseif data_type == POLYNOMIAL
        return "POLYNOMIAL"
    elseif data_type == PWL
        return "PWL"
    elseif data_type <: Integer
        # We currently don't convert integers stored in TimeSeries.TimeArrays to floats.
        # This is a workaround.
        return "CONSTANT"
    else
        error("$data_type is not supported in forecast data")
    end
end

function _write_time_series_attributes!(
    storage::Hdf5TimeSeriesStorage,
    ts::T,
    path,
) where {T <: StaticTimeSeries}
    _write_time_series_attributes_common!(storage, ts, path)
end

function _write_time_series_attributes!(
    storage::Hdf5TimeSeriesStorage,
    ts::T,
    path,
) where {T <: Forecast}
    _write_time_series_attributes_common!(storage, ts, path)
    interval = get_interval(ts)
    HDF5.attributes(path)["interval"] = time_period_conversion(interval).value
end

function _write_time_series_attributes_common!(storage::Hdf5TimeSeriesStorage, ts, path)
    initial_timestamp = Dates.datetime2epochms(get_initial_timestamp(ts))
    resolution = get_resolution(ts)
    data_type = get_data_type(ts)
    HDF5.attributes(path)["module"] = string(parentmodule(typeof(ts)))
    HDF5.attributes(path)["type"] = string(nameof(typeof(ts)))
    HDF5.attributes(path)["initial_timestamp"] = initial_timestamp
    HDF5.attributes(path)["resolution"] = time_period_conversion(resolution).value
    HDF5.attributes(path)["data_type"] = data_type
end

function _read_time_series_attributes(
    storage::Hdf5TimeSeriesStorage,
    path,
    rows,
    ::Type{T},
) where {T <: StaticTimeSeries}
    return _read_time_series_attributes_common(storage, path, rows)
end

function _read_time_series_attributes(
    storage::Hdf5TimeSeriesStorage,
    path,
    rows,
    ::Type{T},
) where {T <: Forecast}
    data = _read_time_series_attributes_common(storage, path, rows)
    data["interval"] = Dates.Millisecond(HDF5.read(HDF5.attributes(path)["interval"]))
    return data
end

const _TYPE_DICT = Dict("CONSTANT" => CONSTANT, "POLYNOMIAL" => POLYNOMIAL, "PWL" => PWL)

function _read_time_series_attributes_common(storage::Hdf5TimeSeriesStorage, path, rows)
    initial_timestamp =
        Dates.epochms2datetime(HDF5.read(HDF5.attributes(path)["initial_timestamp"]))
    resolution = Dates.Millisecond(HDF5.read(HDF5.attributes(path)["resolution"]))
    data_type = _TYPE_DICT[HDF5.read(HDF5.attributes(path)["data_type"])]
    return Dict(
        "type" => _read_time_series_type(path),
        "initial_timestamp" => initial_timestamp,
        "resolution" => resolution,
        "dataset_size" => size(path["data"]),
        "start_time" => initial_timestamp + resolution * (rows.start - 1),
        "data_type" => data_type,
    )
end

function _read_time_series_type(path)
    module_str = HDF5.read(HDF5.attributes(path)["module"])
    type_str = HDF5.read(HDF5.attributes(path)["type"])
    return get_type_from_strings(module_str, type_str)
end

function add_time_series_reference!(
    storage::Hdf5TimeSeriesStorage,
    component_uuid::UUIDs.UUID,
    name::AbstractString,
    ts_uuid::UUIDs.UUID,
)
    check_read_only(storage)
    uuid = string(ts_uuid)
    component_name = make_component_name(component_uuid, name)
    HDF5.h5open(storage.file_path, "r+") do file
        root = _get_root(storage, file)
        path = root[uuid]
        _append_item!(path, "components", component_name)
        @debug "Add reference to existing time series entry." uuid component_uuid name
    end
end

# TODO: This needs to change if we want to directly convert Hdf5TimeSeriesStorage to
# InMemoryTimeSeriesStorage, which is currently not supported System deserialization.
function iterate_time_series(storage::Hdf5TimeSeriesStorage)
    Channel() do channel
        HDF5.h5open(storage.file_path, "r") do file
            root = _get_root(storage, file)
            for uuid_group in root
                uuid_path = HDF5.name(uuid_group)
                uuid_str = uuid_path[(findlast("/", uuid_path).start + 1):end]
                uuid = UUIDs.UUID(uuid_str)

                data = uuid_group["data"][:]
                attributes = Dict()
                for name in keys(HDF5.attributes(uuid_group))
                    attributes[name] = HDF5.read(HDF5.attributes(uuid_group)[name])
                end
                for item in HDF5.read(uuid_group["components"])
                    component, name = deserialize_component_name(item)
                    put!(channel, (component, name, data, attributes))
                end
            end
        end
    end
end

#=
# This could be used if we deserialize the type directly from HDF.
function _make_rows_columns(dataset, ::Type{T}) where T <: StaticTimeSeries
    rows = UnitRange(1, size(dataset)[1])
    columns = UnitRange(1, 1)
    return (rows, columns)
end

function _make_rows_columns(dataset, ::Type{T}) where T <: Forecast
    rows = UnitRange(1, size(dataset)[1])
    columns = UnitRange(1, size(dataset)[2])
    return (rows, columns)
end
=#

function remove_time_series!(
    storage::Hdf5TimeSeriesStorage,
    uuid::UUIDs.UUID,
    component_uuid::UUIDs.UUID,
    name::AbstractString,
)
    check_read_only(storage)
    HDF5.h5open(storage.file_path, "r+") do file
        root = _get_root(storage, file)
        path = _get_time_series_path(root, uuid)
        if _remove_item!(path, "components", make_component_name(component_uuid, name))
            @debug "$path has no more references; delete it."
            HDF5.delete_object(path)
        end
    end
end

function deserialize_time_series(
    ::Type{T},
    storage::Hdf5TimeSeriesStorage,
    ts_metadata::TimeSeriesMetadata,
    rows::UnitRange,
    columns::UnitRange,
) where {T <: StaticTimeSeries}
    # Note that all range checks must occur at a higher level.
    return HDF5.h5open(storage.file_path, "r") do file
        root = _get_root(storage, file)
        uuid = get_time_series_uuid(ts_metadata)
        path = _get_time_series_path(root, uuid)
        attributes = _read_time_series_attributes(storage, path, rows, T)
        @assert_op attributes["type"] == T
        @debug "deserializing a StaticTimeSeries" T
        data_type = attributes["data_type"]
        data = get_hdf_array(path["data"], data_type, rows)
        return T(
            ts_metadata,
            TimeSeries.TimeArray(
                range(
                    attributes["start_time"];
                    length = length(rows),
                    step = attributes["resolution"],
                ),
                data,
            ),
        )
    end
end

function deserialize_time_series(
    ::Type{T},
    storage::Hdf5TimeSeriesStorage,
    ts_metadata::TimeSeriesMetadata,
    rows::UnitRange,
    columns::UnitRange,
) where {T <: AbstractDeterministic}
    # Note that all range checks must occur at a higher level.
    return HDF5.h5open(storage.file_path, "r") do file
        root = _get_root(storage, file)
        uuid = get_time_series_uuid(ts_metadata)
        path = _get_time_series_path(root, uuid)
        actual_type = _read_time_series_type(path)
        if actual_type == SingleTimeSeries
            last_index = size(path["data"])[1]
            return deserialize_deterministic_from_single_time_series(
                storage,
                ts_metadata,
                rows,
                columns,
                last_index,
            )
        end

        attributes = _read_time_series_attributes(storage, path, rows, T)
        @assert actual_type <: T "actual_type = $actual_type T = $T"
        @debug "deserializing a Forecast" T
        data_type = attributes["data_type"]
        data = get_hdf_array(path["data"], data_type, attributes, rows, columns)
        new_ts = actual_type(ts_metadata, data)
    end
end

function get_hdf_array(
    dataset,
    ::Type{<:CONSTANT},
    attributes::Dict{String, Any},
    rows::UnitRange{Int},
    columns::UnitRange{Int},
)
    data = SortedDict{Dates.DateTime, Vector{Float64}}()
    initial_timestamp = attributes["start_time"]
    interval = attributes["interval"]
    start_time = initial_timestamp + interval * (columns.start - 1)
    if length(columns) == 1
        data[start_time] = dataset[rows, columns.start]
    else
        data_read = dataset[rows, columns]
        for (i, it) in
            enumerate(range(start_time; length = length(columns), step = interval))
            data[it] = @view data_read[1:length(rows), i]
        end
    end
    return data
end

function get_hdf_array(
    dataset,
    type::Type{POLYNOMIAL},
    attributes::Dict{String, Any},
    rows::UnitRange{Int},
    columns::UnitRange{Int},
)
    data = SortedDict{Dates.DateTime, Vector{POLYNOMIAL}}()
    initial_timestamp = attributes["start_time"]
    interval = attributes["interval"]
    start_time = initial_timestamp + interval * (columns.start - 1)
    if length(columns) == 1
        data[start_time] = retransform_hdf_array(dataset[rows, columns.start, :], type)
    else
        data_read = retransform_hdf_array(dataset[rows, columns, :], type)
        for (i, it) in
            enumerate(range(start_time; length = length(columns), step = interval))
            data[it] = @view data_read[1:length(rows), i]
        end
    end
    return data
end

function get_hdf_array(
    dataset,
    type::Type{PWL},
    attributes::Dict{String, Any},
    rows::UnitRange{Int},
    columns::UnitRange{Int},
)
    data = SortedDict{Dates.DateTime, Vector{PWL}}()
    initial_timestamp = attributes["start_time"]
    interval = attributes["interval"]
    start_time = initial_timestamp + interval * (columns.start - 1)
    if length(columns) == 1
        data[start_time] = retransform_hdf_array(dataset[rows, columns.start, :, :], type)
    else
        data_read = retransform_hdf_array(dataset[rows, columns, :, :], type)
        for (i, it) in
            enumerate(range(start_time; length = length(columns), step = interval))
            data[it] = @view data_read[1:length(rows), i]
        end
    end
    return data
end

function get_hdf_array(dataset, type::Type{<:CONSTANT}, rows::UnitRange{Int})
    data = retransform_hdf_array(dataset[rows], type)
    return data
end

function get_hdf_array(dataset, type::Type{POLYNOMIAL}, rows::UnitRange{Int})
    data = retransform_hdf_array(dataset[rows, :, :], type)
    return data
end

function get_hdf_array(dataset, type::Type{PWL}, rows::UnitRange{Int})
    data = retransform_hdf_array(dataset[rows, :, :, :], type)
    return data
end

function retransform_hdf_array(data::Array, ::Type{<:CONSTANT})
    return data
end

function retransform_hdf_array(data::Array, T::Type{POLYNOMIAL})
    row, column, tuple_length = get_data_dims(data, T)
    if isnothing(column)
        t_data = Array{POLYNOMIAL}(undef, row)
        for r in 1:row
            t_data[r] = tuple(data[r, 1:tuple_length]...)
        end
    else
        t_data = Array{POLYNOMIAL}(undef, row, column)
        for r in 1:row, c in 1:column
            t_data[r, c] = tuple(data[r, c, 1:tuple_length]...)
        end
    end
    return t_data
end

function retransform_hdf_array(data::Array, T::Type{PWL})
    row, column, tuple_length, array_length = get_data_dims(data, T)
    if isnothing(column)
        t_data = Array{PWL}(undef, row)
        for r in 1:row
            tuple_array = Array{POLYNOMIAL}(undef, array_length)
            for l in 1:array_length
                tuple_array[l] = tuple(data[r, 1:tuple_length, l]...)
            end
            t_data[r] = tuple_array
        end
    else
        t_data = Array{PWL}(undef, row, column)
        for r in 1:row, c in 1:column
            tuple_array = Array{POLYNOMIAL}(undef, array_length)
            for l in 1:array_length
                tuple_array[l] = tuple(data[r, c, 1:tuple_length, l]...)
            end
            t_data[r, c] = tuple_array
        end
    end
    return t_data
end

function get_data_dims(data::Array, ::Type{POLYNOMIAL})
    if length(size(data)) == 2
        row, tuple_length = size(data)
        return (row, nothing, tuple_length)
    elseif length(size(data)) == 3
        return size(data)
    else
        error("Hdf data array is $(length(size(data)))-D array, expected 2-D or 3-D array.")
    end
end

function get_data_dims(data::Array, ::Type{PWL})
    if length(size(data)) == 3
        row, tuple_length, array_length = size(data)
        return (row, nothing, tuple_length, array_length)
    elseif length(size(data)) == 4
        return size(data)
    else
        error("Hdf data array is $(length(size(data)))-D array, expected 3-D or 4-D array.")
    end
end

function deserialize_time_series(
    ::Type{T},
    storage::Hdf5TimeSeriesStorage,
    ts_metadata::TimeSeriesMetadata,
    rows::UnitRange,
    columns::UnitRange,
) where {T <: Probabilistic}
    # Note that all range checks must occur at a higher level.
    total_percentiles = length(get_percentiles(ts_metadata))

    return HDF5.h5open(storage.file_path, "r") do file
        root = _get_root(storage, file)
        uuid = get_time_series_uuid(ts_metadata)
        path = _get_time_series_path(root, uuid)
        attributes = _read_time_series_attributes(storage, path, rows, T)
        @assert_op attributes["type"] == T
        @assert_op length(attributes["dataset_size"]) == 3
        @debug "deserializing a Forecast" T
        data = SortedDict{Dates.DateTime, Matrix{attributes["data_type"]}}()
        initial_timestamp = attributes["start_time"]
        interval = attributes["interval"]
        start_time = initial_timestamp + interval * (first(columns) - 1)
        if length(columns) == 1
            data[start_time] =
                transpose(path["data"][1:total_percentiles, rows, first(columns)])
        else
            data_read = PermutedDimsArray(
                path["data"][1:total_percentiles, rows, columns],
                [3, 2, 1],
            )
            for (i, it) in enumerate(
                range(start_time; length = length(columns), step = attributes["interval"]),
            )
                data[it] = @view data_read[i, 1:length(rows), 1:total_percentiles]
            end
        end

        new_ts = T(ts_metadata, data)
    end
end

function deserialize_time_series(
    ::Type{T},
    storage::Hdf5TimeSeriesStorage,
    ts_metadata::TimeSeriesMetadata,
    rows::UnitRange,
    columns::UnitRange,
) where {T <: Scenarios}
    # Note that all range checks must occur at a higher level.
    total_scenarios = get_scenario_count(ts_metadata)

    return HDF5.h5open(storage.file_path, "r") do file
        root = _get_root(storage, file)
        uuid = get_time_series_uuid(ts_metadata)
        path = _get_time_series_path(root, uuid)
        attributes = _read_time_series_attributes(storage, path, rows, T)
        @assert_op attributes["type"] == T
        @assert_op length(attributes["dataset_size"]) == 3
        @debug "deserializing a Forecast" T
        data = SortedDict{Dates.DateTime, Matrix{attributes["data_type"]}}()
        initial_timestamp = attributes["start_time"]
        interval = attributes["interval"]
        start_time = initial_timestamp + interval * (first(columns) - 1)
        if length(columns) == 1
            data[start_time] =
                transpose(path["data"][1:total_scenarios, rows, first(columns)])
        else
            data_read =
                PermutedDimsArray(path["data"][1:total_scenarios, rows, columns], [3, 2, 1])
            for (i, it) in enumerate(
                range(start_time; length = length(columns), step = attributes["interval"]),
            )
                data[it] = @view data_read[i, 1:length(rows), 1:total_scenarios]
            end
        end

        new_ts = T(ts_metadata, data)
    end
end

function clear_time_series!(storage::Hdf5TimeSeriesStorage)
    check_read_only(storage)
    # Re-create the file. HDF5 will not actually free up the deleted space until h5repack
    # is run on the file.
    _make_file(storage)
    @info "Cleared all time series."
end

function get_num_time_series(storage::Hdf5TimeSeriesStorage)
    num = 0

    HDF5.h5open(storage.file_path, "r") do file
        root = _get_root(storage, file)
        for component in root
            num += 1
        end
    end

    return num
end

function _make_file(storage::Hdf5TimeSeriesStorage)
    HDF5.h5open(storage.file_path, "w") do file
        HDF5.create_group(file, HDF5_TS_ROOT_PATH)
    end
end

_get_root(storage::Hdf5TimeSeriesStorage, file) = file[HDF5_TS_ROOT_PATH]

function _get_time_series_path(root::HDF5.Group, uuid::UUIDs.UUID)
    uuid_str = string(uuid)
    if !haskey(root, uuid_str)
        throw(ArgumentError("UUID $uuid_str does not exist"))
    end

    return root[uuid_str]
end

function _append_item!(path::HDF5.Group, name::AbstractString, value::AbstractString)
    handle = HDF5.open_object(path, name)
    values = HDF5.read(handle)
    HDF5.close(handle)

    if in(value, values)
        # Just in case any component tries to store the same reference twice.
        return nothing
    else
        push!(values, value)
    end

    # Delete and re-write.
    HDF5.delete_object(path, name)
    path[name] = values
    @debug "Appended $value to $name" values
end

"""
Removes value from the dataset called name.
Returns true if the array is empty afterwards.
"""
function _remove_item!(path::HDF5.Group, name::AbstractString, value::AbstractString)
    handle = HDF5.open_object(path, name)
    vals = HDF5.read(handle)
    HDF5.close(handle)

    orig_len = length(vals)
    filter!(x -> x != value, vals)
    exp_len = orig_len - 1
    if length(vals) != exp_len
        throw(
            ArgumentError(
                "$value wasn't stored in $name or was stored more than once. " *
                "exp_len = $exp_len actual = $(length(vals))",
            ),
        )
    end

    # Delete and rewrite.
    # This is not efficient, but this is expected to be uncommon and not to have
    # large counts.
    HDF5.delete_object(path, name)
    path[name] = vals

    @debug "Removed $value from $name" vals
    return isempty(vals)
end

function check_read_only(storage::Hdf5TimeSeriesStorage)
    if storage.read_only
        error("Operation not permitted; this time series file is read-only")
    end
end

is_read_only(storage::Hdf5TimeSeriesStorage) = storage.read_only

function compare_values(x::Hdf5TimeSeriesStorage, y::Hdf5TimeSeriesStorage)::Bool
    item_x = sort!(collect(iterate_time_series(x)), by = z -> z[1])
    item_y = sort!(collect(iterate_time_series(y)), by = z -> z[1])
    if length(item_x) != length(item_y)
        @error "lengths don't match" length(item_x) length(item_y)
        return false
    end

    for ((uuid_x, name_x, data_x, attrs_x), (uuid_y, name_y, data_y, attrs_y)) in
        zip(item_x, item_y)
        if uuid_x != uuid_y
            @error "component UUIDs don't match" uuid_x uuid_y
            return false
        end
        if name_x != name_y
            @error "names don't match" name_x name_y
            return false
        end
        if data_x != data_y
            @error "data doesn't match" data_x data_y
            return false
        end
        if sort!(collect(keys(attrs_x))) != sort!(collect(keys(attrs_y)))
            @error "attr keys don't match" attrs_x attrs_y
        end
        if collect(values(attrs_x)) != collect(values(attrs_y))
            @error "attr values don't match" attrs_x attrs_y
        end
    end

    return true
end
