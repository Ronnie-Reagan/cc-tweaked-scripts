--------------------------------------------------------------------
--  Logging
--------------------------------------------------------------------
local logging = require("logging")
local log = logging.getLogger("core", logging.levels.WARNING)
log:addHandler(logging.FileHandler:new())
log:info("System Logging Started")

--------------------------------------------------------------------
--  Dependencies / Display
--------------------------------------------------------------------
local mon = peripheral.wrap("top")
local screenWidth, screenHeight

if not http then error("HTTP API disabled. Enable it in CC:Tweaked config.", 0) end

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
local controlMode 		  = false
local maxPlaybackErrors   = 5                                       -- Playback errors from speakers before resyncing speakers
local volume              = 1                                       -- Volume Float — 0.00 to 3.00 with 1.00 being 100% volume
local skipRequested       = false                                   -- State Signal for Skip Forwards (simple)
local skipBack            = false                                   -- State Signal to Skip Backwards (simple)
local RECENT_TRACK_MEMORY = 128                                     -- Recent track count for shuffling: too high can consume excess memory
local songs               = nil                                     -- Fetched audio dictionary
local recent              = {}                                      -- Recently played song object
local recentIndex		  = 0										-- Holds the 1 based index for recent tracak usage via skip back/forth
local currentSong         = "Not Playing"                           -- Currently playing song name
local SAMPLE_RATE         = 48000                                   -- DFPWM sample rate
local CHUNK_MS            = 200                                      -- Chunk size in time — should be at or above 50 for stability
local SAMPLES_PER_CHUNK   = SAMPLE_RATE * (CHUNK_MS / 1000)         -- PCM smaples per chunk
local BYTES_PER_CHUNK     = math.floor(SAMPLES_PER_CHUNK / 8)       -- 8 samples per byte
local SUB_CHUNKS          = 8                                       -- Sub-Chunks for decoding
local SUB_CHUNK_BYTES     = math.ceil(BYTES_PER_CHUNK / SUB_CHUNKS) -- PCM bytes per sub chunk
local PLAY_AHEAD_MS       = 400                                     -- Offset ahead of now to send audio; to be played with wait—sync timing
local MAX_BUFFERED_MS     = 2000                                    -- Rolling buffer target, must be above play-ahead by atleast 50 ms


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
		if delta > 10 then
			os.sleep(delta / 1000)
		else
			os.sleep(0)
		end
	end
end

local function silenceFrame(ms)
	local samples = math.floor(SAMPLE_RATE * (20 / 1000))
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
		refreshInterval = refreshInterval or 60000,
	}, Speakers)
end

function Speakers:_scan()
	local found = { peripheral.find("speaker") }
	local list = {}
	for i = 1, #found do
		list[i] = {
			object = found[i],
			bad = false,
			errors = 0,
			id = peripheral.getName(found[i]),
			latency = i * 0.01
		}
	end
	return list
end

function Speakers:sorter(a, b)
	if not a or not b then return end
	return (a.latency or 0) > (b.latency or 0)
end

function Speakers:sortByLatencyCheap()
	if #self.list < 2 then return end
	table.sort(self.list, self.sorter)
	log:debug("Speakers sorted by latency")
end

function Speakers:sortByLatencyExpensive()
	if #self.list < 2 then return end

	local function createHeader(speaker)
		return "    " .. speaker.id .. "\n"
	end

	local function createBody(speaker)
		local indent = "        "
		local str = ""
		for i, entry in pairs(speaker) do
			str = str .. indent .. tostring(i) .. ":" .. tostring(entry) .. "\n"
		end
		return str
	end

	table.sort(self.list, self.sorter)
	local speakerList = "--------Sorted Speaker List--------\n"
	for i, speaker in pairs(self.list) do
		speakerList = speakerList .. createHeader(speaker) .. createBody(speaker)
	end
	log:debug(speakerList)
end

function Speakers:refresh()
	self.list = self:_scan()
	self.lastRefresh = os.epoch("utc")
	log:debug("Speaker list refreshed; count=" .. tostring(#self.list))
end

function Speakers:resetBad()
	local silence = silenceFrame(330)

	for _, entry in pairs(self.list) do
		if entry.bad then
			for _ = 1, 2 do
				local ok = entry.object.playAudio(silence, 0.2)
				if ok then
					os.sleep()
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
	local now = os.epoch("utc")

	if now - self.lastRefresh >= self.refreshInterval
		or (#self.list < 1 and now - self.lastRefresh >= 15000 * 60)
	then
	log:debug(("Speaker Updating now=%d last=%d diff=%d interval=%d count=%d")
  :format(now, self.lastRefresh, now - self.lastRefresh, self.refreshInterval, #self.list))
		self:refresh()
		self:resetBad()
		self:sortByLatencyCheap()
	end
	self:resetBad()
end

function Speakers:get()
	self:update()
	return self.list
end

function Speakers:timedPlay(speaker, pcm, vol, start)
	local finish, alpha, dt, acceptedAudio = 0, 0.2, 0, true
	acceptedAudio = speaker.object.playAudio(pcm, vol or 1)
	finish = os.epoch("utc")
	dt = finish - start
	speaker.latency = speaker.latency == 0 and dt or (speaker.latency * (1 - alpha) + dt * alpha)
	return acceptedAudio, dt
end

-- Barrier-synchronized playback across all speakers
function Speakers:blockingPlay(pcm, vol, deadline)
	self:update()
	local now, speaker = os.epoch("utc"), nil

	for i = 1, #self.list do
		speaker = self.list[i]
		if not speaker.bad then
			local offset = speaker.latency or 0
			local enqueueTime = deadline - offset

			if enqueueTime > now then
				waitUntil(enqueueTime)
			end

			local ok, dt = self:timedPlay(speaker, pcm, vol or 1, now)
			if not ok then
				speaker.errors = speaker.errors + 1
				if speaker.errors >= maxPlaybackErrors then
					speaker.bad = true
					log:debug("Speaker " .. speaker.id .. " quarantined")
				end
			else
				speaker.errors = 0
			end
		end
	end

	return os.epoch("utc")
end

local speakerManager = Speakers:new(3600000)

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
	recentIndex = #recent
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
	local buffered_ms  = 0 -- total ms worth of frames queued

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
				os.sleep()
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
				os.sleep(PLAY_AHEAD_MS / 1000)
				break
			else
				os.sleep()
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
				recentIndex = math.max(1, recentIndex - 1)
				song = recent[recentIndex]
			else
				song = pickNextSong()
			end
			skipBack      = false
			skipRequested = false

		elseif skipRequested then
			-- forward skip: advance immediately
			if recentIndex < #recent then
				recentIndex = recentIndex + 1
				song = recent[recentIndex]
			else
				song = pickNextSong()
				recentIndex = #recent
			end
			skipRequested = false

		else
			-- natural progression
			if recentIndex < #recent then
				recentIndex = recentIndex + 1
				song = recent[recentIndex]
			else
				song = pickNextSong()
			end
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
		elseif key == 80 and controlMode then -- Character Key 'P'
			Speakers.sortByLatencyExpensive(speakerManager)
		end
		if key == 341 then -- left control
			controlMode = not controlMode
			log:debug("Control mode active = " .. (controlMode and "active" or "disabled"))
		end
		if controlMode then
			log:debug(key)
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
	local localEnd   = range  -- 1, 2, 3

	local localPct   = (vol - localStart) / (localEnd - localStart)
	if localPct < 0 then localPct = 0 end
	if localPct > 1 then localPct = 1 end

	local units = math.floor(localPct * maxUnits + 0.001)

	local bar = "|" .. string.rep(symbol, units)
		.. string.rep("_", maxUnits - units) .. "|"

	return bar, symbol, range, math.floor(volume * 100 + 0.5)
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
		term.write(string.format("%3d%% / %d00%%", pct, range))

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
