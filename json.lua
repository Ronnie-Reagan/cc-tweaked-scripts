-- json.lua - https://github.com/rxi/json.lua
-- Place this file in your root or 'rom/apis' folder

local json = {}

local encode, decode

local function encode_value(v)
    if type(v) == "nil" then
        return "null"
    elseif type(v) == "boolean" then
        return tostring(v)
    elseif type(v) == "number" then
        return tostring(v)
    elseif type(v) == "string" then
        return string.format("%q", v)
    elseif type(v) == "table" then
        local is_array = true
        local max = 0
        for k,vv in pairs(v) do
            if type(k) ~= "number" then
                is_array = false
                break
            else
                if k > max then max = k end
            end
        end
        local items = {}
        if is_array then
            for i = 1,max do
                table.insert(items, encode_value(v[i]))
            end
            return "[" .. table.concat(items, ",") .. "]"
        else
            for k,vv in pairs(v) do
                table.insert(items, encode_value(k) .. ":" .. encode_value(vv))
            end
            return "{" .. table.concat(items, ",") .. "}"
        end
    else
        error("Unsupported type: " .. type(v))
    end
end

function json.encode(v)
    return encode_value(v)
end

local function decode_string(s, i)
    i = i + 1 -- skip quote
    local res = ""
    while true do
        local c = s:sub(i,i)
        if c == '"' then
            return res, i+1
        elseif c == "\\" then
            i = i + 1
            local esc = s:sub(i,i)
            if esc == "n" then res = res .. "\n"
            elseif esc == "r" then res = res .. "\r"
            elseif esc == "t" then res = res .. "\t"
            elseif esc == "\\" then res = res .. "\\"
            elseif esc == '"' then res = res .. '"'
            else error("Invalid escape: \\"..esc) end
        else
            res = res .. c
        end
        i = i + 1
    end
end

local function decode_object(s, i)
    local res = {}
    i = i + 1 -- skip '{'
    while true do
        i = s:find("%S", i)
        if s:sub(i,i) == "}" then
            return res, i + 1
        end
        local key
        if s:sub(i,i) == '"' then
            key, i = decode_string(s, i)
        else
            error("Expected string key at " .. i)
        end
        i = s:find("%S", i)
        if s:sub(i,i) ~= ":" then error("Expected ':' at " .. i) end
        i = i + 1
        local val
        val, i = decode_value(s, i)
        res[key] = val
        i = s:find("%S", i)
        local c = s:sub(i,i)
        if c == "}" then return res, i+1 end
        if c ~= "," then error("Expected ',' at " .. i) end
        i = i + 1
    end
end

local function decode_array(s, i)
    local res = {}
    i = i + 1 -- skip '['
    while true do
        i = s:find("%S", i)
        if s:sub(i,i) == "]" then
            return res, i + 1
        end
        local val
        val, i = decode_value(s, i)
        table.insert(res, val)
        i = s:find("%S", i)
        local c = s:sub(i,i)
        if c == "]" then return res, i+1 end
        if c ~= "," then error("Expected ',' at " .. i) end
        i = i + 1
    end
end


function decode_value(s, i)
    i = s:find("%S", i)
    local c = s:sub(i,i)
    if c == "{" then
        return decode_object(s, i)
    elseif c == "[" then
        return decode_array(s, i)
    elseif c == '"' then
        return decode_string(s, i)
    elseif c:match("[%d%-]") then
        local j = i
        while s:sub(j,j):match("[%d%.%-eE]") do j = j + 1 end
        local num = tonumber(s:sub(i,j-1))
        return num, j
    elseif s:sub(i,i+3) == "null" then
        return nil, i+4
    elseif s:sub(i,i+3) == "true" then
        return true, i+4
    elseif s:sub(i,i+4) == "false" then
        return false, i+5
    else
        error("Invalid value at " .. i)
    end
end

function json.decode(s)
    local res, _ = decode_value(s, 1)
    return res
end

return json
