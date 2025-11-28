-- tunnel.lua
-- Inventory-aware tunnel digger with emulated inventory for faster lookups
---------------------------------------
--  Config / constants
---------------------------------------
local os = os
local configName = "donfig.json" -- placeholder for future config

-- suffix-based classification (matched against end of block name, e.g. "minecraft:cobblestone")
local PREFERRED_BUILD_SUFFIXES = {"cobblestone"}
local SOLID_JUNK_SUFFIXES = {"diorite", "andesite", "cobbled", "granite", "sandstone", "slab", "tuff"}

local INVENTORY_SLOT_COUNT = 16

---------------------------------------
--  Utils
---------------------------------------
local utils = {
    NON_SOLID_SUFFIXES = {"sand", "gravel", "water", "snow", "branch"}
}

function utils.ends_with(name, suffix)
    if not name or not suffix then
        return false
    end
    if #name < #suffix then
        return false
    end
    return name:sub(-#suffix):lower() == suffix
end

function utils.name_has_any_suffix(name, suffixes)
    if not name or not suffixes then
        return false
    end
    for i = 1, #suffixes do
        if utils.ends_with(name, suffixes[i]) then
            return true
        end
    end
    return false
end

---------------------------------------
--  Inventory model
---------------------------------------
local Inventory = {}
Inventory.__index = Inventory

-- slots[slot]      = itemDetail or nil
-- index[name]      = { total = <count>, slots = {slot1, slot2, ...} }

function Inventory.new()
    local self = setmetatable({
        slots = {},
        index = {},
        opCounter = 0 -- used for periodic full scans
    }, Inventory)

    self:fullScan()
    return self
end

-- fullScan: rebuilds entire inventory model from turtle
function Inventory:fullScan()
    self.slots = {}
    self.index = {}

    for slot = 1, INVENTORY_SLOT_COUNT do
        local data = turtle.getItemDetail(slot)
        self.slots[slot] = data

        if data then
            local name = data.name
            local node = self.index[name]
            if not node then
                node = {
                    total = 0,
                    slots = {}
                }
                self.index[name] = node
            end
            node.total = node.total + data.count
            node.slots[#node.slots + 1] = slot
        end
    end
end

-- internal: remove a slot from index for a specific name
local function removeSlotFromIndex(index, name, slot)
    local node = index[name]
    if not node then
        return
    end

    for i = 1, #node.slots do
        if node.slots[i] == slot then
            table.remove(node.slots, i)
            break
        end
    end

    if node.total <= 0 or #node.slots == 0 then
        index[name] = nil
    end
end

-- updateSlot: resyncs a single slot with live turtle inventory
function Inventory:updateSlot(slot)
    local old = self.slots[slot]
    if old then
        local oldName = old.name
        local node = self.index[oldName]
        if node then
            node.total = node.total - old.count
            removeSlotFromIndex(self.index, oldName, slot)
        end
    end

    local new = turtle.getItemDetail(slot)
    self.slots[slot] = new

    if new then
        local name = new.name
        local node = self.index[name]
        if not node then
            node = {
                total = 0,
                slots = {}
            }
            self.index[name] = node
        end
        node.total = node.total + new.count
        node.slots[#node.slots + 1] = slot
    end
end

-- convenience: update currently selected slot
function Inventory:updateSelected()
    self:updateSlot(turtle.getSelectedSlot())
end

-- periodic consistency check: every N operations, rebuild
function Inventory:tick()
    self.opCounter = self.opCounter + 1
    if (self.opCounter % 32) == 0 then
        self:fullScan()
    end
end

-- find first slot for exact block name
function Inventory:findExact(name)
    local node = self.index[name]
    if not node or not node.slots[1] then
        return nil
    end
    return node.slots[1]
end

-- select slot for exact block name
function Inventory:selectExact(name)
    local slot = self:findExact(name)
    if slot then
        turtle.select(slot)
        return true
    end
    return false
end

-- find any slot whose name ends with one of the suffixes
function Inventory:findBySuffixList(suffixList)
    for name, node in pairs(self.index) do
        if node.total > 0 and utils.name_has_any_suffix(name, suffixList) then
            if node.slots[1] then
                return node.slots[1], name
            end
        end
    end
    return nil
end

-- select any block whose name ends with one of the suffixes
function Inventory:selectBySuffixList(suffixList)
    local slot = self:findBySuffixList(suffixList)
    if slot then
        turtle.select(slot)
        return true
    end
    return false
end

-- count all items with exact name
function Inventory:countExact(name)
    local node = self.index[name]
    return node and node.total or 0
end

-- count all items with name ending in suffix
function Inventory:countBySuffix(suffix)
    local total = 0
    for name, node in pairs(self.index) do
        if utils.ends_with(name, suffix) then
            total = total + (node.total or 0)
        end
    end
    return total
end

-- dump all items whose name ends with suffix
-- if keepOne == true, keep one (first encountered) slot
function Inventory:dumpBySuffix(suffix, keepOne)
    local kept = keepOne and 1 or 0
    local slotCount, itemCount = 0, 0

    -- simple approach: operate at slot level, rescan once after
    for slot = 1, INVENTORY_SLOT_COUNT do
        local data = self.slots[slot]
        if data and utils.ends_with(data.name, suffix) then
            if keepOne and kept > 0 then
                kept = kept - 1
            else
                turtle.select(slot)
                turtle.drop()
                slotCount = slotCount + 1
                itemCount = itemCount + data.count
            end
        end
    end

    if itemCount > 0 then
        self:fullScan()
    end

    return itemCount >= 1, slotCount, itemCount
end

-- select best block for building (roof/wall/floor)
function Inventory:selectBestBuildingBlock()
    -- preferred: cobblestone (and similar)
    if self:selectBySuffixList(PREFERRED_BUILD_SUFFIXES) then
        return true
    end

    -- fallback: solid junk
    if self:selectBySuffixList(SOLID_JUNK_SUFFIXES) then
        return true
    end

    return false
end

-- select a torch (any block whose name ends in "torch")
function Inventory:selectTorch()
    return self:selectBySuffixList({"torch"})
end

---------------------------------------
--  Placement Logic
---------------------------------------
local placement = {}
local currentInventory -- shared upvalue for placement + movement

function placement.setInventory(inventory)
    currentInventory = inventory
end

function placement.place(dir)
    local inv = currentInventory
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

---------------------------------------
--  movement movement / tunnel logic
---------------------------------------
local movement = {}

function movement.setInventory(inventory)
    currentInventory = inventory
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

function movement.forceForward(maxAttempts)
    maxAttempts = maxAttempts or 20
    local attempts = 0
    local inv = currentInventory

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

function movement.forceDown(maxAttempts)
    maxAttempts = maxAttempts or 20
    local attempts = 0
    local inv = currentInventory

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

function movement.attemptRoof()
    if not isSolid("up") then
        placement.place("up")
    end
end

function movement.attemptFloor()
    if not isSolid("down") then
        placement.place("down")
    end
end

---------------------------------------
--  Display Logic
---------------------------------------

local function printLine(toPrint, shouldClear, clearType, centerOnPos, x, y)
    if shouldClear then
        if clearType and clearType == "full" then
            term.clear()
        else
            if not x or not y then
                term.clear()
            else
                term.setCursorPos(x, y)
                term.clearLine()
            end
        end
    end
    if x and y then
        if centerOnPos then
            term.setCursorPos(math.floor(math.floor(x / 2) - math.ceil(#toPrint / 2)), math.floor(y))
            term.write(toPrint)
        else
            term.setCursorPos(x, y)
            term.write(toPrint)
        end
    else
        term.write(toPrint)
    end
end

---------------------------------------
--  High-level tunnel routine
---------------------------------------
local inv = Inventory.new()
placement.setInventory(inv)
movement.setInventory(inv)

local function proceedForward()
    -- step forward
    if not movement.forceForward() then
        print("Failed to move forward; aborting layer")
        return false
    end

    -- roof
    movement.attemptRoof()

    -- upper walls
    placement.placeWall("right")
    placement.placeWall("left")

    -- move down to floor
    if not movement.forceDown() then
        print("Failed to move down; aborting layer")
        return false
    end

    -- lower walls
    placement.placeWall("right")
    placement.placeWall("left")

    -- floor
    movement.attemptFloor()

    -- reset back to original height
    turtle.up()
    inv:tick()

    return true
end

local function promptDistance()

    local width, height = term.getSize()
    printLine("Enter Desired Distance", true, "full", true, math.floor(width / 2), math.floor(height / 2))
    term.setCursorPos(1, height)
    term.write("Dist: ")
    term.setCursorBlink(true)
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

    local width, height = term.getSize()
    printLine("Ensure you put fuel, building blocks, and torches in the turtle.", true, "full", true, width / 2, height / 2)
    inv:fullScan()

    if os.epoch("utc") - lastSlept > 5000 then
        lastSlept = os.epoch("utc")
        os.sleep()
    end

    local targetDepth = promptDistance()
    if not targetDepth then
        printLine("Invalid depth; exiting.", true, "full", true, width / 2, height / 2)
        return
    end

    term.clear()
    term.setCursorPos(1, 1)
    print("Now starting to mine...")
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

            -- dump excess cobblestone but keep one slot
            inv:dumpBySuffix("cobblestone", true)
        end

        os.sleep()
    end

    print("All Done, Returning to start now")
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

    printLine("Thank you for tunneling with my script :).", true, "full", true, 1, 1)
    term.setCursorPos(1, 2)
    term.write(">")
end

main()
