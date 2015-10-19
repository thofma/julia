# This file is a part of Julia. License is MIT: http://julialang.org/license

function select_block_test(t1, t2, t3)
    c1 = Channel{Symbol}(1)
    c2 = Channel{Int}(1)
    c3 = Channel(1)

    put!(c3,1)

    local response

    @schedule begin
        sleep(t1)
        put!(c1,:a)
    end

    @schedule begin
        sleep(t2)
        put!(c2,1)
    end

    @schedule begin
        sleep(t3)
        take!(c3)
    end

    @select begin
        if c1 |> x
            response = "Got $x from c1"
        elseif c2
            response = "Got a message from c2"
        elseif c3 <| :write_test
            response = "Wrote to c3"
        end
    end

    response
end

@test select_block_test(.5, 1, 1) == "Got a from c1"
@test select_block_test(1, .5, 1) == "Got a message from c2"
@test select_block_test(1, 1, .5) == "Wrote to c3"

function select_nonblock_test(test)
    c = Channel(1)
    c2 = Channel(1)
    put!(c2, 1)
    if test == :take
        put!(c, 1)
    elseif test == :put
        take!(c2)
    elseif test == :default
    end
    local response
    @select begin
        if c |> x
            response = "Got $x from c"
        elseif c2 <| 1
            response = "Wrote to c2"
        else
            response = "Default case"
        end
    end
    response
end

@test select_nonblock_test(:take) == "Got 1 from c"
@test select_nonblock_test(:put) == "Wrote to c2"
@test select_nonblock_test(:default) == "Default case"

let c = Channel(1)
    @test select([(:take, c, nothing), (:put, c, :msg)]) == (2, :msg)
    @test select([(:take, c, nothing), (:put, c, :msg)]) == (1, :msg)
end
