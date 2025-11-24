-- Placement Logic
local placement = {}
local inv

function placement.setInventory(inventory)
    inv = inventory
end

function placement.place(dir)
    if not inv then
        return false
    end

    if not inv:selectBestBuildingBlock() then
        os.sleep(0.1)
        return false
    end

    local ok = false
    if dir == "up" then
        ok = turtle.placeUp()
    elseif dir == "down" then
        ok = turtle.placeDown()
    else
        ok = turtle.place()
    end

    inv:updateSelected()
    inv:tick()
    return ok
end

function placement.placeWall(side)
    local turn

    if side == "right" then
        turn = function(back)
            if back then
                turtle.turnLeft()
            else
                turtle.turnRight()
            end
        end
    elseif side == "left" then
        turn = function(back)
            if back then
                turtle.turnRight()
            else
                turtle.turnLeft()
            end
        end
    end

    if turn then
        turn(false)
    end
    placement.place()
    if turn then
        turn(true)
    end
end

return placement
