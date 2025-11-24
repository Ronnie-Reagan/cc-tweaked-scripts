-- Inventory Logic
local utils = require "utils"

-- suffix-based classification (matched against end of block name, e.g. "minecraft:cobblestone")
local PREFERRED_BUILD_SUFFIXES = {"cobblestone"}
local SOLID_JUNK_SUFFIXES = {"diorite", "andesite", "cobbled", "granite", "sandstone", "slab", "tuff"}

local INVENTORY_SLOT_COUNT = 16
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
-- if keepOne == true, keep one stack worth (first encountered)
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

return Inventory
