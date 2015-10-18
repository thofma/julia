function select_test(t1, t2, t3)
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

@test select_test(.5, 1, 1) == "Got a from c1"
@test select_test(1, .5, 1) == "Got a message from c2"
@test select_test(1, 1, .5) == "Wrote to c3"
