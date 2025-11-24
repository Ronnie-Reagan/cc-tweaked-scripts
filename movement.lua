-- Core movement Logic
local core = {}
local utils = require "utils"
local placement = require "placement"
local inv


function core.setInventory(inventory)
    inv = inventory
end

local function isSolid(dir)
    local isBlock, data

    if dir == "up" then
        isBlock, data = turtle.inspectUp()
    elseif dir == "down" then
        isBlock, data = turtle.inspectDown()
    else
        isBlock, data = turtle.inspect()
    end

    if not isBlock then
        return false
    end

    if not data or not data.name then
        return false
    end

    if utils.name_has_any_suffix(data.name, utils.NON_SOLID_SUFFIXES) then
        return false
    end

    -- everything else is treated as solid enough
    return true
end

function core.forceForward(maxAttempts)
    maxAttempts = maxAttempts or 20
    local attempts = 0

    while not turtle.forward() do
        attempts = attempts + 1

        if turtle.dig() and inv then
            inv:fullScan()
        end

        os.sleep(0.25)

        if attempts >= maxAttempts then
            return false
        end
    end

    if inv then
        inv:tick()
    end
    return true
end

function core.forceDown(maxAttempts)
    maxAttempts = maxAttempts or 20
    local attempts = 0

    while not turtle.down() do
        attempts = attempts + 1

        if turtle.digDown() and inv then
            inv:fullScan()
        end

        os.sleep(0.25)

        if attempts >= maxAttempts then
            return false
        end
    end

    if inv then
        inv:tick()
    end
    return true
end

function core.attemptRoof()
    if not isSolid("up") then
        placement.place("up")
    end
end

function core.attemptFloor()
    if not isSolid("down") then
        placement.place("down")
    end
end

return core
