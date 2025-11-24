-- tunnel_builder.lua
-- inventory-aware tunnel digger with emulated inventory for faster lookups
---------------------------------------
-- config / constants
---------------------------------------
local os = os
local configName = "donfig.json" -- not used yet; placeholder for future config
local inventory = require "inventory"
local placement = require "placement"
local core = require "movement"
local inv = inventory.new()
placement.setInventory(inv)
core.setInventory(inv)

local function proceedForward()
    -- step forward
    if not core.forceForward() then
        print("Failed to move forward; aborting layer")
        return false
    end

    -- roof
    core.attemptRoof()

    -- upper walls
    placement.placeWall("right")
    placement.placeWall("left")

    -- move down to floor
    if not core.forceDown() then
        print("Failed to move down; aborting layer")
        return false
    end

    -- lower walls
    placement.placeWall("right")
    placement.placeWall("left")

    -- floor
    core.attemptFloor()

    -- reset back to original height
    turtle.up()
    inv:tick()

    return true
end

local function promptDistance()
    print("Enter tunnel depth in blocks (forward):")
    local line = read()
    local input = tonumber(line)
    if input and input > 0 then
        return input
    end
end

local function main()

    local lastSlept = os.epoch("utc")
    os.sleep()

    if os.epoch("utc") - lastSlept > 5000 then
        lastSlept = os.epoch("utc")
        os.sleep()
    end

    print("Ensure you put fuel, building blocks, and torches in the turtle.")
    inv:fullScan()

    if os.epoch("utc") - lastSlept > 5000 then
        lastSlept = os.epoch("utc")
        os.sleep()
    end
    local targetDepth = promptDistance()
    if not targetDepth then
        print("Invalid depth; exiting.")
        return
    end

    for i = 1, targetDepth do
        if not proceedForward() then
            print("Stopped early at depth " .. i)
            break
        end

        if os.epoch("utc") - lastSlept > 5000 then
            lastSlept = os.epoch("utc")
            os.sleep()
        end
        -- every 5 blocks: place torch and clear excess cobble
        if (i % 5) == 0 then
            if inv:selectTorch() then
                turtle.placeDown()
                inv:updateSelected()
            end

            -- dump excess cobblestone but keep one stack equivalent
            inv:dumpBySuffix("cobblestone", true)
        end

        os.sleep()
    end

    -- turn around and walk back
    turtle.turnRight()
    turtle.turnRight()

    if os.epoch("utc") - lastSlept > 5000 then
        lastSlept = os.epoch("utc")
        os.sleep()
    end

    for _ = 1, targetDepth do

        if os.epoch("utc") - lastSlept > 5000 then
            lastSlept = os.epoch("utc")
            os.sleep()
        end
        if not turtle.forward() then
            turtle.dig()
            os.sleep()
        end

    end

    print("All done.")
end

main()
