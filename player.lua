--------------------------------------------------------------------
--  Logging
--------------------------------------------------------------------
local logging = require("logging")
local log = logging.getLogger("core", logging.levels.INFO)
log:addHandler(logging.FileHandler:new())
log:info("System Logging Started")

--------------------------------------------------------------------
--  Dependencies / Display
--------------------------------------------------------------------
local mon = peripheral.wrap("top")
local screenWidth, screenHeight

if mon then
    mon.setTextScale(1)
    term.redirect(mon)
    screenWidth, screenHeight = mon.getSize()
else
    screenWidth, screenHeight = term.getSize()
end

local json  = require("json")
local dfpwm = require("cc.audio.dfpwm")
local wrap  = require("cc.strings").wrap

-- For emulators (optional)
if periphemu ~= nil then
    print("Speaker created on top: " .. periphemu.create("top", "speaker"))
    os.sleep(1) -- to ensure reading time
end

--------------------------------------------------------------------
--  Globals / Config
--------------------------------------------------------------------
local maxPlaybackErrors         = 5         -- Playback errors from speakers before resyncing speakers
local volume                    = 1         -- Volume Float — 0.00 to 3.00 with 1.00 being 100% volume
local skipRequested             = false     -- State Signal for Skip Forwards (simple)
local skipBack                  = false     -- State Signal to Skip Backwards (simple)
local RECENT_TRACK_MEMORY       = 32        -- Recent track count for shuffling: too high can consume excess memory
local songs                     = nil       -- Fetched audio dictionary
local recent                    = {}        -- Recently played song object
local currentSong               = "Not Playing" -- Currently playing song name

-- Audio timing / chunking
local SAMPLE_RATE               = 48000                               -- DFPWM sample rate
local CHUNK_MS                  = 50                                  -- Chunk size in time — should be at or above 50 for stability
local SAMPLES_PER_CHUNK         = SAMPLE_RATE * (CHUNK_MS / 1000)     -- PCM smaples per chunk
local BYTES_PER_CHUNK           = math.floor(SAMPLES_PER_CHUNK / 8)   -- 8 samples per byte
local SUB_CHUNKS                = 10                                  -- Sub-Chunks for decoding
local SUB_CHUNK_BYTES           = math.ceil(BYTES_PER_CHUNK / SUB_CHUNKS) -- PCM bytes per sub chunk
local PLAY_AHEAD_MS             = 250                                 -- Offset ahead of now to send audio; to be played with wait—sync timing
local MAX_BUFFERED_MS           = 2000                                -- Rolling buffer target, must be above play-ahead by atleast 50 ms


--------------------------------------------------------------------
--  Timing Helpers
--------------------------------------------------------------------
local function waitUntil(target_ms)
    while true do
        local now = os.epoch("utc")
        if now >= target_ms then
            return
        end
        local delta = target_ms - now
        if delta > 5 then
            os.sleep(delta / 1000)
        else
            os.sleep(0)
        end
    end
end

local function silenceFrame(ms)
    local samples = math.floor(SAMPLE_RATE * (ms / 1000))
    local pcm = {}
    for i = 1, samples do
        pcm[i] = 0
    end
    return pcm
end

--------------------------------------------------------------------
--  Speaker Manager (OO Dynamic Peripheral Updater)
--------------------------------------------------------------------
local Speakers = {}
Speakers.__index = Speakers

function Speakers:new(refreshInterval)
    return setmetatable({
        list            = {},
        lastRefresh     = 0,
        refreshInterval = refreshInterval or 2,
    }, Speakers)
end

function Speakers:_scan()
    local found = { peripheral.find("speaker") }
    local list = {}
    for i = 1, #found do
        list[i] = {object = found[i], bad = false, errors = 0, id = tostring("spk-" .. i)}
    end
    return list
end

function Speakers:refresh()
    self.list = self:_scan()
    self.lastRefresh = os.clock()
    log:debug("Speaker list refreshed; count=" .. tostring(#self.list))
end

function Speakers:resetBad()
    local silence = silenceFrame(330)

    for _, entry in ipairs(self.list) do
        if entry.bad then
            for _ = 1, 3 do
                local ok = entry.object.playAudio(silence, 1)
                if ok then
                    os.sleep(0.9 - _ * 0.1)
                    break
                end
            end
            entry.bad = false
            entry.errors = 0
            log:info("Speaker reset attmpted on device " .. entry.id .. " via silence")
        end
    end
end

function Speakers:update()
    local now = os.clock()
    if now - self.lastRefresh >= self.refreshInterval
        or (#self.list < 1 and now - self.lastRefresh >= 1.5)
    then
        self:refresh()
        self:resetBad()
    end
end

function Speakers:get()
    self:update()
    return self.list
end

-- Barrier-synchronized playback across all speakers
function Speakers:blockingPlay(pcm, vol, time)
    local list = self:get()
    if #list == 0 then
        log:warn("No speakers available for playback.")
        waitUntil(time)
        return os.epoch("utc")
    end

    waitUntil(time)
    for _, spk in pairs(list) do
        if not spk.bad then
            if not spk.object.playAudio(pcm, vol or 1) then
                spk.errors = spk.errors + 1
                if spk.errors >= maxPlaybackErrors then
                    spk.bad = true
                    log:warn("Speaker " .. spk.id .. " quarantined after " .. spk.errors .. " failures")
                end
                return os.epoch("utc")
            end
        end
    end

    return os.epoch("utc")
end

local speakerManager = Speakers:new(10)

--------------------------------------------------------------------
--  Song List / Selection
--------------------------------------------------------------------
local function loadSongList()
    local URL   = "https://pub-050fb801777b4853a0c36256d7ab9b36.r2.dev/songs.json"
    local delay = 1

    while not songs do
        log:info("Attempting to fetch song list...")

        local ok, res = pcall(http.get, URL)
        if ok and res then
            local content = res.readAll()
            res.close()

            local decodeOK, decoded = pcall(json.decode, content)
            if decodeOK and decoded then
                songs = decoded
                break
            else
                log:critical("JSON decode error")
            end
        else
            log:warn("Failed to fetch URL: " .. tostring(URL))
        end

        log:warn("Retry in " .. tostring(delay) .. " seconds.")
        os.sleep(delay)
        delay = delay * 2
    end

    log:info("Fetched " .. #songs .. " songs successfully.")
end

local function pickNextSong()
    if not songs or #songs == 0 then
        return nil
    end

    local indices = {}
    for i = 1, #songs do
        indices[i] = i
    end

    -- Fisher-Yates shuffle
    for i = #indices, 2, -1 do
        local j = math.random(i)
        indices[i], indices[j] = indices[j], indices[i]
    end

    for _, idx in ipairs(indices) do
        if not songs then
            return nil
        end
        local song = songs[idx]
        local skip = false
        for _, r in ipairs(recent) do
            if r.url == song.url then
                skip = true
                break
            end
        end
        if not skip then
            table.insert(recent, song)
            if #recent > RECENT_TRACK_MEMORY then
                table.remove(recent, 1)
            end
            return song
        end
    end

    -- If all are in recent, just pick random
    local choice = songs[math.random(#songs)]
    table.insert(recent, choice)
    if #recent > RECENT_TRACK_MEMORY then
        table.remove(recent, 1)
    end
    return choice
end

local function fetchDFPWM(song)
    if song and song.url and http then
        local ok, res = pcall(http.get, song.url)
        if ok and res then
            local data = res.readAll()
            res.close()
            return data
        else
            log:warn("Failed to fetch song: " .. tostring(song and song.url))
        end
    end
    return nil
end

--------------------------------------------------------------------
--  Audio Playback Core
--------------------------------------------------------------------

local function playSong(songData)
    if skipRequested then
        skipRequested = false
    end

    if not songData then
        log:warn("playSong called with nil data")
        return
    end

    local decoder      = dfpwm.make_decoder()

    -- Schedule: simple queue with head/tail
    local schedule     = {}
    local scheduleHead = 1
    local scheduleTail = 0
    local buffered_ms  = 0  -- total ms worth of frames queued

    local SONG_START   = os.epoch("utc")
    local elapsed_ms   = 0
    local decoderDone  = false
    local dataPos      = 1

    local function scheduleSize()
        return scheduleTail - scheduleHead + 1
    end

    local function queueFrame(deadline, frame, frame_ms)
        local idx = scheduleTail + 1
        schedule[idx] = {
            deadline = deadline,
            frame    = frame,
            frame_ms = frame_ms,
        }
        scheduleTail = idx
        buffered_ms = buffered_ms + (frame_ms or 0)
    end

    local function peekFrame()
        if scheduleHead > scheduleTail then
            return nil
        end
        return schedule[scheduleHead]
    end

    local function popFrame()
        if scheduleHead > scheduleTail then
            return nil
        end
        local item = schedule[scheduleHead]
        schedule[scheduleHead] = nil
        scheduleHead = scheduleHead + 1
        if scheduleHead > scheduleTail then
            scheduleHead = 1
            scheduleTail = 0
        end
        buffered_ms = buffered_ms - (item.frame_ms or 0)
        if buffered_ms < 0 then
            buffered_ms = 0
        end
        return item
    end

    -- read encoded DFPWM sub-chunk (bytes)
    local function readSubChunk()
        if dataPos > #songData then
            return nil
        end
        local chunk = songData:sub(dataPos, dataPos + SUB_CHUNK_BYTES - 1)
        dataPos = dataPos + #chunk
        return chunk
    end

    -- decode one PCM "frame" ≈ CHUNK_MS ms, in SUB_CHUNKS small reads
    local function decodeFrame()
        local pcmAll = {}

        for _ = 1, SUB_CHUNKS do
            local encoded = readSubChunk()
            if not encoded or #encoded == 0 then
                -- End of data; return partial frame if we have any samples
                return (#pcmAll > 0) and pcmAll or nil
            end

            local pcm = decoder(encoded)
            if pcm then
                for i = 1, #pcm do
                    pcmAll[#pcmAll + 1] = pcm[i]
                end
            end
        end

        if #pcmAll == 0 then
            return nil
        end
        return pcmAll
    end

    -- Decoder Task: build schedule with time-based buffering
    local function decoderTask()
        while true do
            if skipRequested then
                break
            end

            -- Respect max buffered time
            while buffered_ms >= MAX_BUFFERED_MS and not skipRequested do
                os.sleep(0)
            end
            if skipRequested then
                break
            end

            local frame = decodeFrame()
            if not frame then
                decoderDone = true
                break
            end

            local frame_ms = (#frame / SAMPLE_RATE) * 1000
            elapsed_ms = elapsed_ms + frame_ms

            local deadline = SONG_START + math.floor(elapsed_ms + PLAY_AHEAD_MS)

            queueFrame(deadline, frame, frame_ms)

            -- yield to let playback task catch up
            os.sleep()
        end
    end

    -- Playback Task: wait for deadlines & feed speakers in sync
    local function playbackTask()
        while true do
            if skipRequested then
                break
            end

            local item = peekFrame()
            if item then
                speakerManager:blockingPlay(item.frame, volume, item.deadline)
                popFrame()
            elseif decoderDone then
                -- No frames and decoder is done —> song finished
                os.sleep(PLAY_AHEAD_MS)
                break
            else
                os.sleep(1.5)
            end
        end
    end

    parallel.waitForAll(decoderTask, playbackTask)
end

--------------------------------------------------------------------
--  Main Tasks
--------------------------------------------------------------------
local function audioTask()
    log:info("Audio Task starting")

    while true do
        local song
        if skipBack then
            -- previous song in recent list
            if #recent > 1 then
                song = recent[math.max(1, #recent - 1)]
            else
                song = pickNextSong()
            end
            skipBack      = false
            skipRequested = false
        else
            song = pickNextSong()
        end

        if song then
            local data = fetchDFPWM(song)
            if data then
                currentSong = song.title or "Unknown Title"
                playSong(data)
            else
                log:warn("Song fetch failed; retry in 1s")
                os.sleep(1)
            end
        else
            log:warn("No songs available; retry in 5s")
            os.sleep(5)
        end
    end
end

--------------------------------------------------------------------
--  UI / Input
--------------------------------------------------------------------
local buttons = {
    [1] = {
        symbol = "Vol +",
        label  = "Vol +",
        x      = function()
            local x, y = term.getSize()
            screenWidth, screenHeight = x, y
            return screenWidth - 5
        end,
        width  = 5,
        y      = function()
            local x, y = term.getSize()
            screenWidth, screenHeight = x, y
            return screenHeight - 2
        end,
        height = 1,
        func   = function()
            volume = math.min(3, volume + 0.05)
        end,
    },

    [2] = {
        symbol = "Vol -",
        label  = "Vol -",
        x      = function()
            local x, y = term.getSize()
            screenWidth, screenHeight = x, y
            return screenWidth - 5
        end,
        width  = 5,
        y      = function()
            local x, y = term.getSize()
            screenWidth, screenHeight = x, y
            return screenHeight - 1
        end,
        height = 1,
        func   = function()
            volume = math.max(0, volume - 0.05)
        end,
    },

    [3] = {
        symbol = "<<<",
        label  = "back",
        x      = function()
            local x, y = term.getSize()
            screenWidth, screenHeight = x, y
            return 1
        end,
        width  = 6,
        y      = function()
            local x, y = term.getSize()
            screenWidth, screenHeight = x, y
            return screenHeight - 1
        end,
        height = 1,
        func   = function()
            skipBack      = true
            skipRequested = true
        end,
    },

    [4] = {
        symbol = ">>>",
        label  = "skip",
        x      = function()
            local x, y = term.getSize()
            screenWidth, screenHeight = x, y
            return 7
        end,
        width  = 6,
        y      = function()
            local x, y = term.getSize()
            screenWidth, screenHeight = x, y
            return screenHeight - 1
        end,
        height = 1,
        func   = function()
            skipRequested = true
        end,
    },
}

local function activateButton(x, y)
    for _, button in pairs(buttons) do
        local bx, by = button.x(), button.y()
        if x >= bx and x <= bx + button.width - 1 and
            y >= by and y <= by + button.height - 1 then
            button.func()
        end
    end
end

local function touchWatcher()
    log:info("Touch-Watcher starting")
    while true do
        local event, side, x, y = os.pullEvent("monitor_touch")
        activateButton(x, y)
        log:info("Monitor Touch on side '" .. tostring(side)
            .. "' at X/Y " .. tostring(x) .. "/" .. tostring(y))
    end
end

local function keyWatcher()
    log:info("Key-Watcher starting")

    while true do
        local ev, key = os.pullEvent("key")
        if key == keys.right then
            skipRequested = true
        elseif key == keys.left then
            skipBack      = true
            skipRequested = true
        elseif key == keys.up then
            volume = math.min(3, volume + 0.05)
        elseif key == keys.down then
            volume = math.max(0, volume - 0.05)
        end
    end
end

--------------------------------------------------------------------
--  Volume Bar Helpers
--------------------------------------------------------------------
local function getVolumeSymbol(v)
    if v <= 1 then
        return "x"
    elseif v <= 2 then
        return "X"
    else
        return "!"
    end
end

local function getVolumeRange(v)
    if v <= 1 then
        return 1
    elseif v <= 2 then
        return 2
    else
        return 3
    end
end

local function buildVolumeBar(vol)
    local maxUnits   = 10

    local symbol     = getVolumeSymbol(vol)
    local range      = getVolumeRange(vol)

    local localStart = range - 1 -- 0, 1, 2
    local localEnd   = range     -- 1, 2, 3

    local localPct   = (vol - localStart) / (localEnd - localStart)
    if localPct < 0 then localPct = 0 end
    if localPct > 1 then localPct = 1 end

    local units = math.floor(localPct * maxUnits + 0.001)

    local bar = "|" .. string.rep(symbol, units)
        .. string.rep("_", maxUnits - units) .. "|"

    return bar, symbol, range, math.floor(localPct * 100 + 0.5)
end

local function drawUI()
    while true do
        os.sleep(0.25)

        local timeDisplay = textutils.formatTime(os.time("local"))
        local width, height = term.getSize()
        screenWidth, screenHeight = width, height

        local songLines = wrap(currentSong, width - 2)

        local bar, symbol, range, pct = buildVolumeBar(volume)

        term.clear()

        -- Clock
        term.setCursorPos(1, 1)
        term.write(timeDisplay)

        -- Now Playing
        term.setCursorPos(1, 3)
        term.write("Now Playing:")

        for i = 1, #songLines do
            term.setCursorPos(2, i + 4)
            term.write(songLines[i])
        end

        -- Volume bar (right side)
        term.setCursorPos(width - (#bar + 4), 1)
        term.write("Vol. " .. bar)

        term.setCursorPos(width - 16, 2)
        local volPct = math.floor(volume * 100 + 0.5)
        term.write(string.format("%3d%% / %d00%%", volPct, range))

        -- Buttons
        for _, button in pairs(buttons) do
            term.setCursorPos(button.x(), button.y())
            term.write(button.symbol or button.label)
        end
    end
end

--------------------------------------------------------------------
--  Initialization / Main
--------------------------------------------------------------------
local seed = os.epoch("utc") % 100000
math.randomseed(seed)
log:debug("Seed = " .. seed)

loadSongList()
speakerManager:update()
os.sleep(0.25)
parallel.waitForAny(audioTask, keyWatcher, touchWatcher, drawUI)
