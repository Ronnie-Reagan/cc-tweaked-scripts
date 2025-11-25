--------------------------------------------------------------------
--  Logging
--------------------------------------------------------------------
local logging = require("logging")
local log = logging.getLogger("core", logging.levels.DEBUG)
log:addHandler(logging.FileHandler:new())
log:info("System Logging Started")

--------------------------------------------------------------------
--  Dependencies
--------------------------------------------------------------------
local json = require("json")
local dfpwm = require("cc.audio.dfpwm")
local wrap = require("cc.strings").wrap

if periphemu ~= nil then
	print("Monitor created on top: " .. periphemu.create("top", "speaker"))
end

--------------------------------------------------------------------
--  Globals / Config
--------------------------------------------------------------------
local volume = 1
local skipRequested = false
local skipBack = false
local RECENT_TRACK_MEMORY = 32
local CHUNK_MS = 100 -- chunk time in ms; may need to be > tps
local CHUNK_SIZE = math.floor(48000 * (CHUNK_MS / 1000))
local SUB_CHUNK_SIZE = math.ceil(CHUNK_SIZE / 10)
local SUB_CHUNKS = 10
local PLAY_AHEAD_MS = 15
local MAX_FRAMES_BUFFERED = 80
local songs = nil
local recent = {}
local currentSong = "Not Playing"
-- helpers
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

--------------------------------------------------------------------
--  Speaker Manager (OO Dynamic Peripheral Updater)
--------------------------------------------------------------------
local Speakers = {}
Speakers.__index = Speakers

function Speakers:new(refreshInterval)
    return setmetatable({
        list = {},
        lastRefresh = 0,
        refreshInterval = refreshInterval or 2
    }, Speakers)
end

function Speakers:_scan()
    local found = {peripheral.find("speaker")}
    local list = {}
    for i = 1, #found do
        list[i] = found[i]
    end
    return list
end

function Speakers:refresh()
    self.list = self:_scan()
    self.lastRefresh = os.clock()
    log:debug("Speaker list refreshed; count=" .. tostring(#self.list))
end

function Speakers:update()
    local now = os.clock()
    if now - self.lastRefresh >= self.refreshInterval then
        self:refresh()
    end
end

function Speakers:get()
    self:update()
    return self.list
end

function Speakers:blockingPlay(pcm, vol, time)
    local list = self:get()
    waitUntil(time)
    for _, spk in ipairs(list) do
        if not spk.playAudio(pcm, vol or 1) then
            return
        end
    end
    return os.epoch("utc")
end

local speakerManager = Speakers:new(60)

local function loadSongList()
    local URL = "https://pub-050fb801777b4853a0c36256d7ab9b36.r2.dev/songs.json"
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
    if #songs == 0 then
        return nil
    end

    local indices = {}
    for i = 1, #songs do
        indices[i] = i
    end

    -- Fisher-Yates
    for i = #indices, 2, -1 do
        local j = math.random(i)
        indices[i], indices[j] = indices[j], indices[i]
    end

    for _, idx in ipairs(indices) do
        if songs == nil then
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

    -- If all recent, pick random
    local choice = songs[math.random(#songs)]
    table.insert(recent, choice)
    if #recent > RECENT_TRACK_MEMORY then
        table.remove(recent, 1)
    end
    return choice
end

local function fetchDFPWM(song)
    if song.url and http then
        local ok, res = pcall(http.get, song.url)
        if ok and res then
            local data = res.readAll()
            res.close()
            return data
        else
            log:warn("Failed to fetch song: " .. tostring(song.url))
        end
    end
    return nil
end

local function playSong(songData)
    if skipRequested then
        skipRequested = false
    end
    if not songData then
        log:warn("playSong called with nil data")
        return
    end
    local decoder = dfpwm.make_decoder()
    local schedule = {}
    local scheduleHead = 1
    local scheduleTail = 0
    local SONG_START = os.epoch("utc")
    local elapsed_ms = 0
    local decoderDone = false
    local dataPos = 1

    local function scheduleSize()
        return scheduleTail - scheduleHead + 1
    end

    local function queueFrame(deadline, frame)
        scheduleTail = scheduleTail + 1
        schedule[scheduleTail] = {
            deadline = deadline,
            frame = frame
        }
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
        return item
    end

    -- Internal: read one encoded subchunk
    local function readSubChunk()
        if dataPos > #songData then
            return nil
        end
        local chunk = songData:sub(dataPos, dataPos + SUB_CHUNK_SIZE - 1)
        dataPos = dataPos + #chunk
        return chunk
    end

    -- Internal: decode ~10 chunks into one PCM frame
    local function decodeFrame()
        local pcmAll = {}

        for _ = 1, SUB_CHUNKS do
            local encoded = readSubChunk()
            if not encoded then
                return (#pcmAll > 0) and pcmAll or nil
            end

            local pcm = decoder(encoded)
            if pcm then
                for i = 1, #pcm do
                    pcmAll[#pcmAll + 1] = pcm[i]
                end
            end
        end

        return pcmAll
    end

    -- Decoder Task: Build schedule using deadlines
    local function decoderTask()
        while true do
            if skipRequested then
                break
            end

            local frame = decodeFrame()
            if not frame then
                decoderDone = true
                break
            end

            local frame_ms = (#frame / 48000) * 1000
            elapsed_ms = elapsed_ms + frame_ms

            local deadline = SONG_START + math.floor(elapsed_ms + PLAY_AHEAD_MS)
            while scheduleSize() >= MAX_FRAMES_BUFFERED and not skipRequested do
                os.sleep(0)
            end
            if skipRequested then
                break
            end
            queueFrame(deadline, frame)

            os.sleep()
        end
    end

    -- Playback Task: wait for deadlines & feed speaker
    local function playbackTask()
        while true do
            if skipRequested then
                break
            end
            local frame = peekFrame()

            if frame then
                speakerManager:blockingPlay(frame.frame, volume, frame.deadline)
                popFrame()
            elseif decoderDone then
                break
            else
                os.sleep(0)
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
            song = recent[math.max(1, #recent - 1)]
            skipBack = false
            skipRequested = false
        else
            song = pickNextSong()
        end

        if song then
            local data = fetchDFPWM(song)
            if data then
                currentSong = song.title
                playSong(data)
            else
                log:warn("Song fetch failed; retry in 1s")
                os.sleep(1)
            end
        end
    end
end

local function keyWatcher()
    log:info("Key-Watcher starting")

    while true do
        local ev, key = os.pullEvent("key")
        if key == keys.right then
            skipRequested = true
        elseif key == keys.left then
            skipBack = true
            skipRequested = true
        elseif key == keys.up then
            volume = math.min(3, volume + 0.05)
        elseif key == keys.down then
            volume = math.max(0, volume - 0.05)
        end
    end
end
local function getVolumeSymbol(vol)
    if vol < 1 then
        return "x"
    elseif vol < 2 then
        return "X"
    else
        return "!"
    end
end

local function getVolumeRange(vol)
    if vol < 1 then
        return "1"
    elseif vol < 2 then
        return "2"
    else
        return "3"
    end
end

local function drawUI()
    while true do
        os.sleep()

        local timeDisplay = textutils.formatTime(os.time("local"))
        local width, height = term.getSize()

        local songLines = wrap(currentSong, width - 2)
        local symbol = getVolumeSymbol(volume)
        local range  = getVolumeRange(volume)
        local volPct = math.floor(volume * 100)

        -- Build volume bar: up to 10 units
        local maxUnits = 10
        local units = math.floor(math.min(volume, 3) / 3 * maxUnits)
        local bar = "|" .. string.rep(symbol, units) .. string.rep("_", maxUnits - units) .. "|"

        term.clear()

        -- Clock
        term.setCursorPos(1, 1)
        term.write(timeDisplay)

        -- Song header
        term.setCursorPos(1, 3)
        term.write("Now Playing:")

        -- Song text
        for i = 1, #songLines do
            term.setCursorPos(2, i + 4)
            term.write(songLines[i])
        end

        -- Volume bar
        term.setCursorPos(width - (#bar + 4), 1)
        term.write("Vol. " .. bar)

        -- Volume numeric
        term.setCursorPos(width - 16, 2)
        term.write(volPct .. "% / " .. range .. "00%")
    end
end


--------------------------------------------------------------------
--  Initialization
--------------------------------------------------------------------
local seed = os.epoch("utc") % 100000
math.randomseed(seed)
log:debug("Seed = " .. seed)

loadSongList()
parallel.waitForAny(audioTask, keyWatcher, drawUI)
log:exception("Script reached end unexpectedly.")
