-- install-player.lua
-- Downloads a fixed set of files from Github

local BASE = "https://raw.githubusercontent.com/Ronnie-Reagan/cc-tweaked-scripts/refs/heads/main/"
local FILES = {
    "player.lua",
    "json.lua",
    "logging.lua",
}

local function download(file)
    local url = BASE .. file
    print("Fetching: " .. url)

    local response = http.get(url)
    if not response then
        print("  ERROR: failed to GET")
        return false
    end

    local data = response.readAll()
    response.close()

    if not data or #data == 0 then
        print("  ERROR: empty response")
        return false
    end

    local f = fs.open(file, "w")
    if not f then
        print("  ERROR: cannot write file")
        return false
    end

    f.write(data)
    f.close()

    print("  OK -> " .. file)
    return true
end
print("Installing `player.lua` and dependencies... please wait")
for _, file in ipairs(FILES) do
    download(file)
end

print("Installation Complete; Use `player` in the console to start the script.")
