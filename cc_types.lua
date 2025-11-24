---@meta
---@diagnostic disable: lowercase-global

-- Lightweight CC:Tweaked type hints so Lua LS stops flagging os.sleep/epoch.
---@class CCTweakedOS
---@field sleep fun(time?: number)
---@field epoch fun(clock?: string): number

---@type CCTweakedOS
os = os
