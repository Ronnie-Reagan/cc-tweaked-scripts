local utils = {
    NON_SOLID_SUFFIXES = {"sand", "gravel", "water", "snow", "branch"}
}

function utils.ends_with(name, suffix)
    if not name or not suffix then
        return false
    end
    if #name < #suffix then
        return false
    end
    return name:sub(-#suffix):lower() == suffix
end

function utils.name_has_any_suffix(name, suffixes)
    if not name or not suffixes then
        return false
    end

    for i = 1, #suffixes do
        if utils.ends_with(name, suffixes[i]) then
            return true
        end
    end

    return false
end

return utils
