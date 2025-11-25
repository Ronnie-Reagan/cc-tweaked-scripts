---------------------------------------------------------------------
-- logging.lua
-- Minimal but correct architecture: Logger -> Handlers -> Formatter
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
-- traceback configuration
logging.includeTraceOn = {
    ERROR    = true,
    CRITICAL = true,
}

local function buildTraceback(message)
    local tb = debug.traceback(message, 3)
    return tb
end

---------------------------------------------------------------------
-- FORMATTER
---------------------------------------------------------------------
local Formatter = {}
Formatter.__index = Formatter

function Formatter:new(template)
    return setmetatable({
        template = template or "%(asctime)s [%(level)s] %(message)s"
    }, self)
end

function Formatter:format(levelName, message)
    local t = os.date("*t")
    local ts = string.format(
        "%04d-%02d-%02d %02d:%02d:%02d",
        t.year, t.month, t.day,
        t.hour, t.min, t.sec
    )

    local out = self.template
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
    local formatted = self.formatter:format(levelName, message)
    print(formatted)
end

------------------------- FileHandler ------------------------------
local FileHandler = {}
FileHandler.__index = FileHandler

function FileHandler:new(path, level, formatter)
    return setmetatable({
        path      = path or "log.txt",
        level     = level or logging.levels.DEBUG,
        formatter = formatter or Formatter:new()
    }, self)
end

function FileHandler:emit(levelName, levelValue, message)
    if levelValue < self.level then return end
    local formatted = self.formatter:format(levelName, message)
    local f = io.open(self.path, "a")
    if f then
        f:write(formatted .. "\n")
        f:close()
    end
end

---------------------------------------------------------------------
-- LOGGER OBJECT
---------------------------------------------------------------------
local Logger = {}
Logger.__index = Logger

function Logger:new(name, level)
    return setmetatable({
        name     = name or "root",
        level    = level or logging.levels.DEBUG,
        handlers = {}
    }, self)
end

function Logger:addHandler(handler)
    table.insert(self.handlers, handler)
end

function Logger:_log(levelName, parts)
    local levelValue = logging.levels[levelName]
    if levelValue < self.level then return end

    -- join message parts
    local msgParts = {}
    for i = 1, #parts do
        msgParts[#msgParts+1] = tostring(parts[i])
    end
    local message = table.concat(msgParts, " ")

    -- include traceback if configured
    if logging.includeTraceOn[levelName] then
        message = buildTraceback(message)
    end

    -- dispatch to handlers
    for _, handler in ipairs(self.handlers) do
        handler:emit(levelName, levelValue, message)
    end
end

function Logger:debug(...)      self:_log("DEBUG",      {...}) end
function Logger:info(...)       self:_log("INFO",       {...}) end
function Logger:warn(...)       self:_log("WARNING",    {...}) end
function Logger:error(...)      self:_log("ERROR",      {...}) end
function Logger:critical(...)   self:_log("CRITICAL",   {...}) end
function Logger:exception(...)  self:_log("ERROR",      {...})  end
---------------------------------------------------------------------
-- ROOT LOGGER
---------------------------------------------------------------------
logging.root = Logger:new("root", logging.levels.DEBUG)
logging.getLogger = function(name, level)
    return Logger:new(name, level)
end

-- Expose handlers + formatter
logging.ConsoleHandler = ConsoleHandler
logging.FileHandler    = FileHandler
logging.Formatter      = Formatter

---------------------------------------------------------------------
return logging
