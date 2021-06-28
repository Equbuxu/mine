function generate()
    local radius = 4
    local height = 2
    local blocks = {}
    for x = -radius,radius do
        for z = -radius,radius do
            for y = 0,height do
                if x*x + z*z < radius*radius then
                    table.insert(blocks, {x=x, y=y, z=z})
                end
            end
        end
    end
    return blocks
end