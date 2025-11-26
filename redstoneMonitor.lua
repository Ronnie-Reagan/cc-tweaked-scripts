-- redstone_wave_monitor.lua
-- Standalone redstone analog waveform monitor for CC:Tweaked
-- - Uses a monitor if available, otherwise the local terminal
-- - Shows live waveform of an analog redstone input (0–15)
-- - Adjustable update speed
-- - Trigger level with freeze-on-trigger
-- - Side selection (keys + monitor buttons)
-- - Keybinds:
--      Q          = Quit
--      A / Left   = Previous redstone side
--      D / Right  = Next redstone side
--      Space      = Toggle manual freeze/unfreeze

---------------------------------------
--  Setup: monitor / terminal
---------------------------------------
local mon = peripheral.find("monitor")
local oldTerm

if mon then
    mon.setTextScale(1)
    oldTerm = term.redirect(mon)
else
    mon = term
end

local function getSize()
    return mon.getSize()
end

local width, height = getSize()

---------------------------------------
--  Redstone setup
---------------------------------------
local sides = redstone.getSides()
if #sides == 0 then
    if oldTerm then term.redirect(oldTerm) end
    error("No redstone sides available.")
end

local sideIndex = 1
local side = sides[sideIndex]

---------------------------------------
--  State
---------------------------------------
local history = {}
local maxLen = math.max(1, width - 3) -- width minus 3 chars for scale
local scrollDelay = 0.2               -- seconds between updates
local triggerLevel = 15
local trigger = nil                   -- nil = disabled, number = level
local frozen = false                  -- freeze waveform scrolling
local exiting = false
local current = redstone.getAnalogInput(side) or 0

local header = "Redstone Monitor"
local buttons = {}

---------------------------------------
--  Utilities
---------------------------------------
local function cycleSide(delta)
    sideIndex = sideIndex + delta
    if sideIndex < 1 then
        sideIndex = #sides
    elseif sideIndex > #sides then
        sideIndex = 1
    end
    side = sides[sideIndex]
end

local function levelToY(v)
    -- map 0..15 -> bottom..top
    return height - v - 1
end

---------------------------------------
--  Layout / buttons
---------------------------------------
local function updateButtonLabels()
    buttons = {}

    -- Recompute width/height and maxLen in case monitor size changed
    width, height = getSize()
    maxLen = math.max(1, width - 3)

    -- Clamp history to available width
    while #history > maxLen do
        table.remove(history, 1)
    end

    -- Bottom row: side prev/next + speed -/+
    buttons.btnSidePrev = {
        label = "<",
        x = width - 6,
        y = height,
        func = function()
            cycleSide(-1)
        end
    }
    buttons.btnSideNext = {
        label = ">",
        x = width - 5,
        y = height,
        func = function()
            cycleSide(1)
        end
    }
    buttons.btnSpeedDec = {
        label = "-",
        x = width - 4,
        y = height,
        func = function()
            scrollDelay = math.min(scrollDelay + 0.05, 1.0)
        end
    }
    buttons.btnSpeedInc = {
        label = "+",
        x = width - 3,
        y = height,
        func = function()
            scrollDelay = math.max(scrollDelay - 0.05, 0.05)
        end
    }
    -- Row above bottom: trigger controls
    buttons.btnTrigDec = {
        label = "t",
        x = width - 2,
        y = height,
        func = function()
            triggerLevel = math.max(0, triggerLevel - 1)
            if trigger then trigger = triggerLevel end
        end
    }
    buttons.btnTrigInc = {
        label = "T",
        x = width - 1,
        y = height,
        func = function()
            triggerLevel = math.min(15, triggerLevel + 1)
            if trigger then trigger = triggerLevel end
        end
    }
    buttons.btnTrigToggle = {
        label = (trigger and "X" or "O"),
        x = width,
        y = height,
        func = function()
            if frozen then frozen = false end
            if trigger then
                trigger = nil
            else
                trigger = triggerLevel
            end
            updateButtonLabels()
        end
    }
end

updateButtonLabels()

---------------------------------------
--  Drawing
---------------------------------------
local function drawScale()
    mon.setBackgroundColor(colors.gray)
    mon.setTextColor(colors.red)
    for i = 0, 15 do
        local y = levelToY(i)
        if y >= 1 and y <= height then
            mon.setCursorPos(1, y)
            -- 3 chars: "00[" .. "15["
            local prefix = (i < 10 and " " or "")
            mon.write(prefix .. i .. "[")
        end
    end
end

local function drawButtons()
    mon.setBackgroundColor(colors.gray)
    mon.setTextColor(colors.white)
    for _, btn in pairs(buttons) do
        if btn.x >= 1 and btn.x <= width and btn.y >= 1 and btn.y <= height then
            mon.setCursorPos(btn.x, btn.y)
            mon.write(btn.label)
        end
    end
end

local function drawHud()
    mon.setBackgroundColor(colors.gray)
    mon.setTextColor(colors.black)

    -- Header (avoid scale area)
    local midWidth = math.floor(width / 2)
    local midLabel = math.ceil(#header / 2)
    local headerX = midWidth - midLabel + 1
    if headerX < 4 then headerX = 4 end
    if headerX <= width then
        mon.setCursorPos(headerX, 1)
        mon.write(header)
    end

    -- Line 2: speed + side
    mon.setCursorPos(1, 1)
    mon.write(string.format("Speed: %.2fs", scrollDelay))
    local sideText = "Side: " .. tostring(side)
    local sideX = math.max(4, width - #sideText - 1)
    if sideX >= 4 and sideX <= width then
        mon.setCursorPos(sideX, 1)
        mon.write(sideText)
    end
    local trigText
    if trigger then
        trigText = "Trigger: " .. trigger .. " (ON)"
    else
        trigText = "Trigger: " .. triggerLevel .. " (OFF)"
    end
    mon.setCursorPos(width - #trigText, 2)
    mon.write(trigText)

    -- Key hint line
    mon.setCursorPos(1, height)
    mon.write("Q=Quit  A/D=Side  Space=Freeze")

    drawButtons()
end

local function drawWave()
    mon.setBackgroundColor(colors.gray)
    mon.clear()

    -- layout may need refresh if monitor resized
    updateButtonLabels()
    drawScale()

    -- waveform
    for i, v in ipairs(history) do
        local x = i + 3 -- offset for 3-char scale
        if x >= 4 and x <= width then
            local y = levelToY(v)
            if y >= 1 and y <= height then
                paintutils.drawPixel(x, y, colors.red)
            end
        end
    end

    drawHud()
end

---------------------------------------
--  Hit testing
---------------------------------------
local function inButton(x, y, btn)
    return x == btn.x and y == btn.y
end

---------------------------------------
--  Threads
---------------------------------------
local function monitorTouch()
    -- If we're not actually on a monitor, this will just block forever.
    if mon ~= term then
        while true do
            local _, _, x, y = os.pullEvent("monitor_touch")
            for _, btn in pairs(buttons) do
                if inButton(x, y, btn) then
                    btn.func()
                    break
                end
            end
        end
    else
        while true do
            os.sleep(1)
            newMon = peripheral.find("monitor")
            if newMon then
                oldTerm = term
                mon = newMon
                mon.setTextScale(1)
                oldTerm = term.redirect(mon)
            end
        end
    end
end

local function monitorRedstone()
    while true do
        if not frozen then
            os.pullEvent("redstone")
            current = redstone.getAnalogInput(side) or 0
            if trigger and current >= trigger then
                frozen = true
            end
        else
            sleep()
        end
    end
end

local function monitorKeys()
    while true do
        local _, key = os.pullEvent("key")
        if key == keys.q then
            exiting = true
            return
        elseif key == keys.left or key == keys.a then
            cycleSide(-1)
        elseif key == keys.right or key == keys.d then
            cycleSide(1)
        elseif key == keys.space then
            frozen = not frozen
        end
    end
end

local function drawScreen()
    while true do
        os.sleep()
        if exiting then
            mon.setBackgroundColor(colors.gray)
            mon.setTextColor(colors.black)
            mon.clear()

            local exitMessage = "Exiting..."
            width, height = getSize()
            local x = math.max(1, math.floor(width / 2 - (#exitMessage / 2)))
            local y = math.max(1, math.floor(height / 2))

            mon.setCursorPos(x, y)
            mon.write(exitMessage)
            sleep(1)
            return
        end

        if not frozen then
            table.insert(history, current)
            if #history > maxLen then
                table.remove(history, 1)
            end
        end

        drawWave()
        sleep(scrollDelay)
    end
end

---------------------------------------
--  Run
---------------------------------------
parallel.waitForAny(drawScreen, monitorRedstone, monitorTouch, monitorKeys)

-- Cleanup: restore terminal
if oldTerm then
    term.redirect(oldTerm)
end
term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
print("Redstone Wave Monitor exited.")
