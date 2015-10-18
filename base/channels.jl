# This file is a part of Julia. License is MIT: http://julialang.org/license

abstract AbstractChannel{T}

type Channel{T} <: AbstractChannel{T}
    cond_take::Condition    # waiting for data to become available
    cond_put::Condition     # waiting for a writeable slot
    state::Symbol

    lock::ReentrantLock

    data::Array{T,1}
    szp1::Int               # current channel size plus one
    sz_max::Int             # maximum size of channel
    take_pos::Int           # read position
    put_pos::Int            # write position

    function Channel(sz)
        sz_max = sz == typemax(Int) ? typemax(Int) - 1 : sz
        szp1 = sz > 32 ? 33 : sz+1
        new(Condition(), Condition(), :open, ReentrantLock(),
            Array(T, szp1), szp1, sz_max, 1, 1)
    end
end

for op in [:lock, :unlock]
    @eval $op(c::Channel) = $op(c.lock)
end

const DEF_CHANNEL_SZ=32

Channel(sz::Int = DEF_CHANNEL_SZ) = Channel{Any}(sz)

closed_exception() = InvalidStateException("Channel is closed.", :closed)
function close(c::Channel)
    c.state = :closed
    notify_error(c::Channel, closed_exception())
    c
end
isopen(c::Channel) = (c.state == :open)

type InvalidStateException <: Exception
    msg::AbstractString
    state::Symbol
end

function put!(c::Channel, v, uselock=true)
    !isopen(c) && throw(closed_exception())
    uselock && lock(c)
    d = c.take_pos - c.put_pos
    if (d == 1) || (d == -(c.szp1-1))
        # grow the channel if possible
        if (c.szp1 - 1) < c.sz_max
            if ((c.szp1-1) * 2) > c.sz_max
                c.szp1 = c.sz_max + 1
            else
                c.szp1 = ((c.szp1-1) * 2) + 1
            end
            newdata = Array(eltype(c), c.szp1)
            if c.put_pos > c.take_pos
                copy!(newdata, 1, c.data, c.take_pos, (c.put_pos - c.take_pos))
                c.put_pos = c.put_pos - c.take_pos + 1
            else
                len_first_part = length(c.data) - c.take_pos + 1
                copy!(newdata, 1, c.data, c.take_pos, len_first_part)
                copy!(newdata, len_first_part+1, c.data, 1, c.put_pos-1)
                c.put_pos = len_first_part + c.put_pos
            end
            c.take_pos = 1
            c.data = newdata
        else
            uselock && unlock(c)
            wait(c.cond_put)
            uselock && lock(c)
        end
    end

    c.data[c.put_pos] = v
    c.put_pos = (c.put_pos == c.szp1 ? 1 : c.put_pos + 1)
    notify(c.cond_take, nothing, true, false)  # notify all, since some of the waiters may be on a "fetch" call.
    uselock && unlock(c)
    v
end

push!(c::Channel, v) = put!(c, v)

function fetch(c::Channel)
    wait(c)
    c.data[c.take_pos]
end

function take!(c::Channel, uselock=true)
    !isopen(c) && !isready(c) && throw(closed_exception())
    wait(c)
    uselock && lock(c)
    v = c.data[c.take_pos]
    c.take_pos = (c.take_pos == c.szp1 ? 1 : c.take_pos + 1)
    notify(c.cond_put, nothing, false, false) # notify only one, since only one slot has become available for a put!.
    uselock && unlock(c)
    v
end

shift!(c::Channel) = take!(c)

isready(c::Channel) = (c.take_pos == c.put_pos ? false : true)

function wait(c::Channel)
    while !isready(c)
        wait(c.cond_take)
    end
    nothing
end

function notify_error(c::Channel, err)
    notify_error(c.cond_take, err)
    notify_error(c.cond_put, err)
end

eltype{T}(::Type{Channel{T}}) = T

function n_avail(c::Channel)
    if c.put_pos >= c.take_pos
        return c.put_pos - c.take_pos
    else
        return c.szp1 - c.take_pos + c.put_pos
    end
end

show(io::IO, c::Channel) = print(io, "$(typeof(c))(sz_max:$(c.sz_max),sz_curr:$(n_avail(c)))")

start{T}(c::Channel{T}) = Ref{Nullable{T}}()
function done(c::Channel, state::Ref)
    try
        # we are waiting either for more data or channel to be closed
        state[] = take!(c)
        return false
    catch e
        if isa(e, InvalidStateException) && e.state==:closed
            return true
        else
            rethrow(e)
        end
    end
end
next{T}(c::Channel{T}, state) = (v=get(state[]); state[]=nothing; (v, state))

select_parse_error() = error("Malformed @select statement")

function get_first_if_body(expr)
    while expr.head == :block
        expr = expr.args[2]
    end
    expr.head == :if || select_parse_error()
    expr
end

function parse_select_case(clause::Expr)
    if clause.head == :call
        if clause.args[1] == :|>
            if length(clause.args) == 3
                return (:take, clause.args[2], clause.args[3])
            else
                select_parse_error()
            end
        elseif clause.args[1] == :<|
            if length(clause.args) == 3
                return (:put, clause.args[2], clause.args[3])
            else
                select_parse_error()
            end
        else
            return (:take, clause.args[2], gensym())
        end
    end
end

parse_select_case(channel::Symbol) = (:take, channel, gensym())

macro select(expr)
    select_cases = Any[]
    while true
        # Robustness to whitespace introduing blocks
        expr = get_first_if_body(expr)
        push!(select_cases, parse_select_case(expr.args[1]) => expr.args[2])
        if length(expr.args)==3
            expr = expr.args[3]
        else
            break
        end
    end

    waiters = Expr(:block)
    evalers = Expr(:block)

    for (i, (clause, body)) in enumerate(select_cases)
        if clause[1] == :take
            wait_body = quote
                @schedule begin
                    wait($(esc(clause[2])))
                    lock($(esc(clause[2])))
                    put!(winner_ch, $i)
                end
            end
        elseif clause[1] == :put
            wait_body = quote
                @schedule begin
                    wait($(esc(clause[2])).cond_put)
                    lock($(esc(clause[2])))
                    put!(winner_ch, $i)
                end
            end
        end
        push!(waiters.args, wait_body)
        if clause[1] == :take
            eval_body = quote
                if winner == $i
                    $(esc(clause[3])) = take!($(esc(clause[2])), false)
                    unlock($(esc(clause[2])))
                    $(esc(body))
                end
            end
        elseif clause[1] == :put
            eval_body = quote
                if winner == $i
                    put!($(esc(clause[2])), $(esc(clause[3])), false)
                    unlock($(esc(clause[2])))
                    $(esc(body))
                end
            end
        end
        push!(evalers.args, eval_body)
    end

    quote
        winner_ch = Channel{Int}(1)
        $waiters
        winner = take!(winner_ch)
        $evalers
    end
end
