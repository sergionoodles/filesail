--!nonstrict

local function openFileSail(path)
    if not noctalia.commandExists("filesail") then
        noctalia.notifyError("FileSail", "The filesail launcher is not available on PATH.")
        return
    end

    local argv = { "filesail" }
    if path ~= nil and path ~= "" then
        argv = { "filesail", "--path", path }
    end

    if not noctalia.runAsync(argv) then
        noctalia.notifyError("FileSail", "Could not start the filesail launcher.")
    end
end

function update()
    noctalia.setUpdateInterval(3600000)
    barWidget.setGlyph("folder")
    barWidget.setTooltip("Open FileSail")
end

function onClick()
    openFileSail(nil)
end

function onIpc(event, payload)
    if event == "open" then
        openFileSail(payload)
    end
end
