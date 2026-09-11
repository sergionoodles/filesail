--!nonstrict

local home = noctalia.expandPath("~")
local PAGE_SIZE = 30
local currentPath = home
local entries = {}
local history = {}
local query = ""
local errorMessage = nil
local searchRevision = 0
local page = 1
local totalEntries = 0
local firstEntry = 0
local lastEntry = 0
local maxPage = 1
local loading = false
local directoryRequest = 0
local render

local function joinPath(directory, name)
    if directory == "/" then
        return "/" .. name
    end
    return directory .. "/" .. name
end

local function parentPath(path)
    if path == "/" then
        return "/"
    end
    local parent = path:match("^(.*)/[^/]+/?$")
    if parent == nil or parent == "" then
        return "/"
    end
    return parent
end

local function showError(message)
    errorMessage = message or "Unable to read this folder."
end

local function normalizePath(path)
    local expanded = noctalia.expandPath(path or home)
    if expanded ~= "/" then
        expanded = expanded:gsub("/+$", "")
    end
    return expanded
end

local function clearSearch()
    query = ""
    page = 1
    searchRevision = searchRevision + 1
end

local function loadDirectory(path, onSuccess, requestedQuery, requestedPage)
    local expanded = normalizePath(path)
    local nextQuery = requestedQuery or ""
    local nextPage = requestedPage or 1
    directoryRequest = directoryRequest + 1
    local request = directoryRequest
    loading = true
    errorMessage = nil
    render()

    local pluginDirectory = noctalia.pluginDir()
    if pluginDirectory == nil then
        loading = false
        showError("Could not resolve the FileSail plugin directory.")
        render()
        return false
    end

    local accepted = noctalia.runAsync({
        pluginDirectory .. "/list-directory.sh",
        expanded,
        nextQuery,
        tostring(nextPage),
        tostring(PAGE_SIZE),
    }, function(result)
        if request ~= directoryRequest then
            return
        end
        loading = false
        if result.exitCode ~= 0 or result.stdoutTruncated then
            local message = result.stderr
            if result.stdoutTruncated then
                message = "This directory is too large for the panel listing."
            end
            showError(message)
            render()
            return
        end

        local records = {}
        for record in string.gmatch(result.stdout or "", "([^\0]*)\0") do
            table.insert(records, record)
        end
        local nextTotal = tonumber(records[1] or "0") or 0
        local nextMaxPage = math.max(1, math.ceil(nextTotal / PAGE_SIZE))
        if nextPage > nextMaxPage then
            loadDirectory(expanded, onSuccess, nextQuery, nextMaxPage)
            return
        end

        local nextEntries = {}
        for index = 2, #records do
            local record = records[index]
            if #record >= 3 and string.sub(record, 2, 2) == "\t" then
                local name = string.sub(record, 3)
                table.insert(nextEntries, {
                    name = name,
                    path = joinPath(expanded, name),
                    isDir = string.sub(record, 1, 1) == "d",
                })
            end
        end
        currentPath = expanded
        entries = nextEntries
        query = nextQuery
        page = nextPage
        totalEntries = nextTotal
        maxPage = nextMaxPage
        firstEntry = nextTotal == 0 and 0 or ((nextPage - 1) * PAGE_SIZE + 1)
        lastEntry = math.min(firstEntry + #nextEntries - 1, nextTotal)
        errorMessage = nil
        if onSuccess ~= nil then
            onSuccess()
        end
        render()
    end)

    if not accepted then
        loading = false
        showError("Could not start the directory listing helper.")
        render()
        return false
    end
    return true
end

local function navigateTo(path)
    local previous = currentPath
    return loadDirectory(path, function()
        if previous ~= currentPath then
            table.insert(history, previous)
        end
        clearSearch()
    end, "", 1)
end

local function pathCrumbs(path)
    local result = {}
    local remainder = path
    local accumulated = ""

    if path == home or string.sub(path, 1, #home + 1) == home .. "/" then
        table.insert(result, { label = "~", path = home, glyph = "home" })
        remainder = string.sub(path, #home + 1)
        accumulated = home
    else
        table.insert(result, { label = "/", path = "/", glyph = "folder" })
    end

    for part in string.gmatch(remainder, "[^/]+") do
        if accumulated == "" or accumulated == "/" then
            accumulated = "/" .. part
        else
            accumulated = accumulated .. "/" .. part
        end
        table.insert(result, { label = part, path = accumulated })
    end

    if #result <= 2 then
        return result
    end
    return {
        result[1],
        { label = "…", path = nil },
        result[#result],
    }
end

render = function()
    local children = {}

    local crumbNodes = {}
    local crumbs = pathCrumbs(currentPath)
    for index, crumb in ipairs(crumbs) do
        if index > 1 then
            table.insert(crumbNodes, ui.glyph({ key = "separator-" .. tostring(index), name = "chevron-right", size = 13, color = "on_surface_variant" }))
        end
        if crumb.path == nil then
            table.insert(crumbNodes, ui.label({ key = "ellipsis", text = crumb.label, color = "on_surface_variant" }))
        else
            local isCurrent = crumb.path == currentPath
            table.insert(crumbNodes, ui.button({
                key = "crumb-" .. crumb.path,
                text = crumb.label,
                glyph = crumb.glyph,
                width = index == 1 and 56 or 136,
                tooltip = crumb.path,
                variant = "ghost",
                selected = isCurrent,
                controlSize = "sm",
                onClick = function() navigateTo(crumb.path) end,
            }))
        end
    end

    table.insert(children, ui.row({ gap = 2, align = "center" }, {
        ui.button({ key = "back", glyph = "chevron-left", tooltip = "Back", controlSize = "sm", enabled = #history > 0, onClick = "goBack" }),
        ui.button({ key = "up", glyph = "arrow-up", tooltip = "Parent folder", controlSize = "sm", enabled = currentPath ~= "/", onClick = "goUp" }),
        ui.row({ key = "breadcrumbs", gap = 0, align = "center", flexGrow = 1 }, crumbNodes),
        ui.button({ key = "window", glyph = "external-link", tooltip = "Open in FileSail window", controlSize = "sm", onClick = "openFullManager" }),
        ui.button({ key = "terminal", glyph = "terminal-2", tooltip = "Open terminal here", controlSize = "sm", onClick = "openTerminalHere" }),
        ui.button({ key = "refresh", glyph = "refresh", tooltip = "Refresh", controlSize = "sm", onClick = "refresh" }),
        ui.button({ key = "close", glyph = "close", tooltip = "Close", controlSize = "sm", onClick = "closePanel" }),
    }))

    table.insert(children, ui.input({
        key = "search-" .. tostring(searchRevision),
        placeholder = "Search this folder",
        value = query,
        onChange = "onSearchChanged",
        controlSize = "sm",
    }))

    if loading then
        table.insert(children, ui.column({ gap = 8, padding = 16, align = "center", justify = "center", flexGrow = 1 }, {
            ui.glyph({ name = "loader-2", size = 24, color = "primary" }),
            ui.label({ text = "Loading folder…", color = "on_surface_variant" }),
        }))
    elseif errorMessage ~= nil then
        table.insert(children, ui.column({ gap = 8, padding = 12, fill = "surface_variant" }, {
            ui.label({ text = errorMessage, color = "error", maxLines = 3 }),
            ui.button({ text = "Open full manager", glyph = "external-link", variant = "secondary", onClick = "openFullManager" }),
        }))
    else
        local rows = {}
        local shown = entries
        if #shown == 0 then
            table.insert(rows, ui.label({ key = "empty", text = query == "" and "This folder is empty" or "No matching files", color = "on_surface_variant" }))
        else
            for _, entry in ipairs(shown) do
                table.insert(rows, ui.button({
                    key = entry.path,
                    text = entry.name,
                    glyph = entry.isDir and "folder" or "file",
                    contentAlign = "start",
                    variant = "ghost",
                    onClick = function() openEntry(entry) end,
                }))
            end
        end
        table.insert(children, ui.scroll({ gap = 2, height = 500 }, rows))
        if totalEntries > PAGE_SIZE then
            table.insert(children, ui.row({ gap = 6, align = "center", justify = "center" }, {
                ui.button({ glyph = "chevron-left", tooltip = "Previous page", controlSize = "sm", enabled = page > 1, onClick = "previousPage" }),
                ui.label({ text = tostring(firstEntry) .. "–" .. tostring(lastEntry) .. " of " .. tostring(totalEntries), color = "on_surface_variant" }),
                ui.button({ glyph = "chevron-right", tooltip = "Next page", controlSize = "sm", enabled = page < maxPage, onClick = "nextPage" }),
            }))
        end
    end

    table.insert(children, ui.row({ gap = 8, align = "center" }, {
        ui.label({ text = "FileSail", color = "on_surface_variant", flexGrow = 1 }),
        ui.button({ text = "Open full manager", glyph = "external-link", variant = "secondary", onClick = "openFullManager" }),
    }))

    panel.render(ui.column({ gap = 8, padding = 14, fill = true }, children))
end

function onOpen(context)
    local requested = context
    if requested == nil or requested == "" then
        requested = noctalia.state.get("requestedPath")
    end
    loadDirectory(requested ~= nil and requested ~= "" and requested or currentPath, nil, "", 1)
end

function onSearchChanged(value)
    loadDirectory(currentPath, nil, value or "", 1)
end

function previousPage()
    if page > 1 then
        loadDirectory(currentPath, nil, query, page - 1)
    end
end

function nextPage()
    if page < maxPage then
        loadDirectory(currentPath, nil, query, page + 1)
    end
end

function openEntry(entry)
    if entry.isDir then
        navigateTo(entry.path)
        return
    end

    local opener = nil
    if noctalia.commandExists("xdg-open") then
        opener = "xdg-open"
    elseif noctalia.commandExists("gio") then
        opener = "gio"
    end
    if opener == nil then
        noctalia.notifyError("FileSail", "No default application opener (xdg-open or gio) is available.")
        return
    end

    local argv = opener == "gio" and { opener, "open", entry.path } or { opener, entry.path }
    if not noctalia.runAsync(argv) then
        noctalia.notifyError("FileSail", "Could not open " .. entry.name)
    end
end

function goBack()
    local previous = history[#history]
    if previous ~= nil then
        loadDirectory(previous, function()
            table.remove(history)
            clearSearch()
        end, "", 1)
    end
end

function goUp()
    if currentPath == "/" then
        return
    end
    navigateTo(parentPath(currentPath))
end

function refresh()
    loadDirectory(currentPath, nil, query, page)
end

function openFullManager()
    if not noctalia.commandExists("filesail") then
        noctalia.notifyError("FileSail", "The filesail launcher is not available on PATH.")
        return
    end
    if not noctalia.runAsync({ "filesail", "--path", currentPath }) then
        noctalia.notifyError("FileSail", "Could not start the full FileSail manager.")
        return
    end
    panel.close()
end

local function shellQuote(value)
    return "'" .. string.gsub(value, "'", "'\"'\"'") .. "'"
end

function openTerminalHere()
    local command = "cd -- " .. shellQuote(currentPath) .. " && exec \"${SHELL:-/bin/sh}\""
    if not noctalia.runInTerminal(command) then
        noctalia.notifyError("FileSail", "Could not open a terminal in " .. currentPath)
    end
end

function closePanel()
    panel.close()
end
