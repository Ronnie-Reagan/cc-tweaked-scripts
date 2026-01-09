--------------------------------------------------------------------
--  Logging
--------------------------------------------------------------------
local logging = require("logging")
local log = logging.getLogger("core", logging.levels.INFO)
log:addHandler(logging.FileHandler:new())
log:info("System Logging Started")

--------------------------------------------------------------------
--  Dependencies
--------------------------------------------------------------------
local json  = require("json")
local dfpwm = require("cc.audio.dfpwm")
local wrap  = require("cc.strings").wrap
if not http then return error("no http", 1) end
if periphemu ~= nil then
    print("Speaker created on top: " .. tostring(periphemu.create("top", "speaker")))
    os.sleep(1) -- to ensure reading time
end

--------------------------------------------------------------------
--  Globals / Config
--------------------------------------------------------------------
local closing = false
local volume              = 1
local skipRequested       = false
local skipBack            = false
local RECENT_TRACK_MEMORY = 32
local CHUNK_MS            = 100 -- chunk time in ms; may need to be > tps
local CHUNK_SIZE          = math.floor(48000 * (CHUNK_MS / 1000))
local SUB_CHUNK_SIZE      = math.ceil(CHUNK_SIZE / 10)
local SUB_CHUNKS          = 10
local PLAY_AHEAD_MS       = 15
local MAX_FRAMES_BUFFERED = 80
local songs               = nil
local recent              = {}
local currentSong         = "Not Playing"
local currentSongEpoch    = os.epoch("utc")

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
        list            = {},
        lastRefresh     = 0,
        refreshInterval = refreshInterval or 2
    }, Speakers)
end

function Speakers:_scan()
    local found = { peripheral.find("speaker") }
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
    if now - self.lastRefresh >= self.refreshInterval or (#self.list < 1 and now - self.lastRefresh >= 1.5) then
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

--------------------------------------------------------------------
--  Song List / Selection
--------------------------------------------------------------------
local function loadSongList()
    local URL   = "https://pub-050fb801777b4853a0c36256d7ab9b36.r2.dev/songs.json"
    local delay = 1

    while not songs do
        term.clear()
        term.setCursorPos(1, 1)
        term.write("Attempting to load Songs... " .. (delay <= 2 and tostring(delay) or tostring(delay / delay)))
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
                if delay >= 2 then
                    local ccDecodeOK, ccDecoded = pcall(textutils.unserializeJSON, content)
                    if ccDecodeOK and ccDecoded then
                        songs = ccDecoded
                        break
                    end
                end
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

--------------------------------------------------------------------
--  Audio Playback
--------------------------------------------------------------------
local function playSong(songData)
    if skipRequested then
        skipRequested = false
    end
    if not songData then
        log:warn("playSong called with nil data")
        return
    end

    local decoder        = dfpwm.make_decoder()
    local schedule       = {}
    local scheduleHead   = 1
    local scheduleTail   = 0
    local SONG_START     = os.epoch("utc")
    local elapsed_ms     = 0
    local decoderDone    = false
    local dataPos        = 1

    local function scheduleSize()
        return scheduleTail - scheduleHead + 1
    end

    local function queueFrame(deadline, frame)
        scheduleTail = scheduleTail + 1
        schedule[scheduleTail] = {
            deadline = deadline,
            frame    = frame
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

    local function readSubChunk()
        if dataPos > #songData then
            return nil
        end
        local chunk = songData:sub(dataPos, dataPos + SUB_CHUNK_SIZE - 1)
        dataPos = dataPos + #chunk
        return chunk
    end

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
                currentSong      = song.title or "Untitled"
                currentSongEpoch = os.epoch("utc")  -- sync animation to song start
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
        elseif key == keys.q then
            closing = true
            break
        end
    end
end

--------------------------------------------------------------------
--  Volume Bar Helpers
--------------------------------------------------------------------
local function getVolumeSymbol(v)
    if v <= 1 then return "x"
    elseif v <= 2 then return "X"
    else return "!"
    end
end

local function getVolumeRange(v)
    if v <= 1 then return 1
    elseif v <= 2 then return 2
    else return 3
    end
end

local function buildVolumeBar(vol)
    local maxUnits = 10

    local symbol = getVolumeSymbol(vol)
    local range  = getVolumeRange(vol)

    local localStart = range - 1
    local localEnd   = range

    local localPct = (vol - localStart) / (localEnd - localStart)
    if localPct < 0 then localPct = 0 end
    if localPct > 1 then localPct = 1 end

    local units = math.floor(localPct * maxUnits + 0.001)

    return "|" .. string.rep(symbol, units) .. string.rep("_", maxUnits - units) .. "|",
           symbol,
           range,
           math.floor(localPct * 100)
end

--------------------------------------------------------------------
--  Functional Animation + Layout System (Integrated)
--------------------------------------------------------------------
local function now()
    return os.epoch("utc")
end

local function elapsed_ms(startEpoch)
    return now() - startEpoch
end

local function getSize()
    return term.getSize()
end

-- bounce-offset for horizontal scrolling:
-- textLen > maxWidth: scroll left→right, pause, right→left, pause
local function bounceOffset(epochEntered, textLen, maxWidth, speed, pause)
    if textLen <= maxWidth then
        return 0
    end

    local maxShift = textLen - maxWidth
    local cycle    = 2 * (maxShift / speed) + 2 * pause
    local t        = (elapsed_ms(epochEntered) / 1000) % cycle

    -- left pause
    if t < pause then
        return 0
    end
    t = t - pause

    local forwardTime = maxShift / speed
    if t < forwardTime then
        return math.floor(t * speed)
    end
    t = t - forwardTime

    -- right pause
    if t < pause then
        return maxShift
    end
    t = t - pause

    local backTime = forwardTime
    if t < backTime then
        return maxShift - math.floor(t * speed)
    end

    return 0
end

local function clearRegion(x, y, width)
    term.setCursorPos(x, y)
    term.write((" "):rep(width))
end

local function drawAt(x, y, text)
    term.setCursorPos(x, y)
    term.write(text)
end

local function drawScrollingText(text, x, y, maxWidth, epoch)
    if maxWidth <= 0 then return end
    text = text or ""
    clearRegion(x, y, maxWidth)

    local len = #text
    local off = bounceOffset(epoch, len, maxWidth, 8, 1.0) -- 8 chars/s, 1s pause

    local slice = text:sub(1 + off, off + maxWidth)
    drawAt(x, y, slice)
end

local function makeLayout()
    local w, h = getSize()
    local third = math.floor(w / 3)

    return {
        header = {
            clock = {
                x        = 1,
                y        = 1,
                maxWidth = math.max(8, third - 2),
            },
            title = {
                x        = third + 1,
                y        = 1,
                maxWidth = third - 2,
            },
            volumeBar = {
                x        = (third * 2) + 1,
                y        = 1,
                maxWidth = third - 2,
            },
        },
        body = {
            startY    = 3,
            rowHeight = 1,
            rows      = h - 2,
        }
    }
end

local function renderHeader(layout, pageNum, epoch, state)
    local H = layout.header

    -- clock (static)
    local clockText = state.timeDisplay or ""
    clearRegion(H.clock.x, H.clock.y, H.clock.maxWidth)
    drawAt(H.clock.x, H.clock.y, clockText:sub(1, H.clock.maxWidth))

    -- title (scrolling)
    drawScrollingText(
        state.headerTitle or "",
        H.title.x,
        H.title.y,
        H.title.maxWidth,
        epoch
    )

    -- volume bar (static text region)
    local volStr = "Vol. " .. (state.volumeBarText or "")
    clearRegion(H.volumeBar.x, H.volumeBar.y, H.volumeBar.maxWidth)
    drawAt(H.volumeBar.x, H.volumeBar.y, volStr:sub(1, H.volumeBar.maxWidth))
end

local function renderBody(layout, items, epoch)
    local B = layout.body
    local w, _ = getSize()

    local maxWidth = math.max(1, w - 2)
    local rows = math.min(#items, B.rows)

    for i = 1, rows do
        local y = B.startY + (i - 1) * B.rowHeight
        drawScrollingText(items[i], 2, y, maxWidth, epoch + (i * 97))
    end
end

local function buildForm(pageNumber, epochEnteredPage)
    local layout = makeLayout()

    return function(state)
        term.clear()
        renderHeader(layout, pageNumber, epochEnteredPage, state)
        renderBody(layout, state.rows or {}, epochEnteredPage)
    end
end

--------------------------------------------------------------------
--  UI Task (Animated, Functional)
--------------------------------------------------------------------
local function drawUI()
    local pageNumber = 1
    local lastEpoch  = nil
    local form       = nil

    while true do
        os.sleep(0.05)

        local epoch = currentSongEpoch or now()
        if not form or epoch ~= lastEpoch then
            form = buildForm(pageNumber, epoch)
            lastEpoch = epoch
        end

        local timeDisplay = textutils.formatTime(os.time("local"))

        local vb = { buildVolumeBar(volume) }
        local barText, symbol, range, pct =
            vb[1], vb[2], vb[3], vb[4]

        local rows = {
            "Now Playing:",
            currentSong,
            "",
            ("Volume: %d%% (range %d00%%, symbol %s)"):format(volume * 100, range, symbol),
            "Left/Right: next / previous track",
            "Up/Down : volume",
        }

        local state = {
            headerTitle   = "Don-Player",
            volume        = volume,
            timeDisplay   = timeDisplay,
            volumeBarText = barText,
            rows          = rows,
        }

        form(state)
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

if not closing then
    log:exception("Script reached end unexpectedly.")
else
    term.clear()
    term.setCursorPos(1, 1)
    term.write("Thank you for using my player")
    term.setCursorPos(1, 2)
    term.write("simply enter 'player' in the terminal to start again!")
    term.setCursorPos(1, 3)
end
