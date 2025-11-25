---------------------------------------------------------------------
-- logging.lua

-- Goals:
--  • No uncaught errors
--  • All handler and formatter operations protected
--  • Safe fallback behaviors
--  • No template explosions
--  • Always-working traceback logic
---------------------------------------------------------------------

local logging = {}

---------------------------------------------------------------------
-- LEVELS
---------------------------------------------------------------------
logging.levels = {
    DEBUG    = 10,
    INFO     = 20,
    WARNING  = 30,
    ERROR    = 40,
    CRITICAL = 50,
}

-- enable traceback for high-severity messages
logging.includeTraceOn = {
    ERROR    = true,
    CRITICAL = true,
}

---------------------------------------------------------------------
-- safe traceback builder
---------------------------------------------------------------------
local function buildTraceback(message)
    -- debug may be missing in sandboxed Lua
    if type(debug) ~= "table" or type(debug.traceback) ~= "function" then
        return "[traceback unavailable] " .. tostring(message)
    end

    local ok, tb = pcall(debug.traceback, message, 3)
    if ok and type(tb) == "string" then
        return tb
    end
    return "[traceback failed] " .. tostring(message)
end

---------------------------------------------------------------------
-- FORMATTER
---------------------------------------------------------------------
local Formatter = {}
Formatter.__index = Formatter

function Formatter:new(template)
    -- enforce safe template
    return setmetatable({
        template = type(template) == "string"
            and template
            or "%(asctime)s [%(level)s] %(message)s"
    }, self)
end

function Formatter:format(levelName, message)
    local ok, t = pcall(os.date, "*t")
    if not ok or type(t) ~= "table" then
        t = {year=0,month=0,day=0,hour=0,min=0,sec=0}
    end

    local ts = string.format(
        "%04d-%02d-%02d %02d:%02d:%02d",
        t.year, t.month, t.day,
        t.hour, t.min, t.sec
    )

    local out = self.template

    -- safe gsubs
    out = out:gsub("%%%(asctime%)s", ts)
    out = out:gsub("%%%(level%)s", levelName)
    out = out:gsub("%%%(message%)s", message)

    return out
end

---------------------------------------------------------------------
-- HANDLERS
---------------------------------------------------------------------

----------------------- ConsoleHandler -----------------------------
local ConsoleHandler = {}
ConsoleHandler.__index = ConsoleHandler

function ConsoleHandler:new(level, formatter)
    return setmetatable({
        level     = level or logging.levels.DEBUG,
        formatter = formatter or Formatter:new()
    }, self)
end

function ConsoleHandler:emit(levelName, levelValue, message)
    if levelValue < self.level then return end

    local ok, formatted = pcall(self.formatter.format, self.formatter, levelName, message)
    if not ok then
        formatted = "[formatter error] " .. tostring(message)
    end

    local okPrint = pcall(print, formatted)
    if not okPrint then
        -- absolutely cannot allow a print failure to kill logging
        -- fallback: nothing
    end
end

------------------------- FileHandler ------------------------------
local FileHandler = {}
FileHandler.__index = FileHandler

function FileHandler:new(path, level, formatter)
    return setmetatable({
        path      = tostring(path or "log.txt"),
        level     = level or logging.levels.DEBUG,
        formatter = formatter or Formatter:new()
    }, self)
end

function FileHandler:emit(levelName, levelValue, message)
    if levelValue < self.level then return end

    local ok, formatted = pcall(self.formatter.format, self.formatter, levelName, message)
    if not ok then
        formatted = "[formatter error] " .. tostring(message)
    end

    local f, err = io.open(self.path, "a")
    if not f then
        -- Fail silently. Logging must never break the program.
        return
    end

    local _ = f:write(formatted .. "\n")
    f:close()
end

---------------------------------------------------------------------
-- LOGGER OBJECT
---------------------------------------------------------------------
local Logger = {}
Logger.__index = Logger

function Logger:new(name, level)
    return setmetatable({
        name     = tostring(name or "root"),
        level    = level or logging.levels.DEBUG,
        handlers = {}
    }, self)
end

function Logger:addHandler(handler)
    if type(handler) == "table" and handler.emit then
        self.handlers[#self.handlers+1] = handler
    end
end

-- INTERNAL LOGGER CORE
function Logger:_log(levelName, parts)
    local levelValue = logging.levels[levelName]
    if not levelValue then return end
    if levelValue < self.level then return end

    -- safe stringify
    local msgParts = {}
    for i = 1, #parts do
        local p = parts[i]
        if p == nil then p = "nil" end
        msgParts[#msgParts+1] = tostring(p)
    end
    local message = table.concat(msgParts, " ")

    -- optional traceback
    if logging.includeTraceOn[levelName] then
        message = buildTraceback(message)
    end

    -- handler dispatch (individually protected)
    for i = 1, #self.handlers do
        local handler = self.handlers[i]
        pcall(handler.emit, handler, levelName, levelValue, message)
    end
end

-- LEVEL METHODS
function Logger:debug(...)      self:_log("DEBUG",      {...}) end
function Logger:info(...)       self:_log("INFO",       {...}) end
function Logger:warn(...)       self:_log("WARNING",    {...}) end
function Logger:error(...)      self:_log("ERROR",      {...}) end
function Logger:critical(...)   self:_log("CRITICAL",   {...}) end
function Logger:exception(...)  self:_log("ERROR",      {...}) end

---------------------------------------------------------------------
-- FACTORY + ROOT
---------------------------------------------------------------------
logging.root = Logger:new("root", logging.levels.DEBUG)

function logging.getLogger(name, level)
    return Logger:new(name, level)
end

logging.ConsoleHandler = ConsoleHandler
logging.FileHandler    = FileHandler
logging.Formatter      = Formatter

return logging
