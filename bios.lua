function os.version()
  return "miniBIOS 0.0.dev-4"
end

function os.pullEventRaw(s)
    return coroutine.yield(s)
end

function os.pullEvent(sFilter)
    local eventData = table.pack(os.pullEventRaw(sFilter))
    if eventData[1] == "terminate" then
        error("Terminated", 0)
    end
    return table.unpack(eventData, 1, eventData.n)
end

function sleep(n)
    local timer = os.startTimer(n or 0)
    repeat
        local _, param = os.pullEvent("timer")
    until param == timer
end

function write(sText)

    local w, h = term.getSize()
    local x, y = term.getCursorPos()

    local nLinesPrinted = 0
    local function newLine()
        if y + 1 <= h then
            term.setCursorPos(1, y + 1)
        else
            term.setCursorPos(1, h)
            term.scroll(1)
        end
        x, y = term.getCursorPos()
        nLinesPrinted = nLinesPrinted + 1
    end

    sText = tostring(sText)
    while #sText > 0 do
        local whitespace = string.match(sText, "^[ \t]+")
        if whitespace then
            term.write(whitespace)
            x, y = term.getCursorPos()
            sText = string.sub(sText, #whitespace + 1)
        end

        local newline = string.match(sText, "^\n")
        if newline then
            newLine()
            sText = string.sub(sText, 2)
        end

        local text = string.match(sText, "^[^ \t\n]+")
        if text then
            sText = string.sub(sText, #text + 1)
            if #text > w then
                while #text > 0 do
                    if x > w then
                        newLine()
                    end
                    term.write(text)
                    text = string.sub(text, w - x + 2)
                    x, y = term.getCursorPos()
                end
            else
                if x + #text - 1 > w then
                    newLine()
                end
                term.write(text)
                x, y = term.getCursorPos()
            end
        end
    end

    return nLinesPrinted
end

function print(...)
    local nLinesPrinted = 0
    local nLimit = select("#", ...)
    for n = 1, nLimit do
        local s = tostring(select(n, ...))
        if n < nLimit then
            s = s .. "\t"
        end
        nLinesPrinted = nLinesPrinted + write(s)
    end
    nLinesPrinted = nLinesPrinted + write("\n")
    return nLinesPrinted
end


function loadfile(filename, mode, env)
    if type(mode) == "table" and env == nil then
        mode, env = nil, mode
    end

    local file = fs.open(filename, "r")
    if not file then return nil, "File not found" end

    local func, err = load(file.readAll(), "@" .. fs.getName(filename), mode, env)
    file.close()
    return func, err
end

function dofile(_sFile)
    local fnFile, e = loadfile(_sFile, nil, _G)
    if fnFile then
        return fnFile()
    else
        error(e, 2)
    end
end

function os.run(_tEnv, _sPath, ...)
    local tEnv = _tEnv
    setmetatable(tEnv, { __index = _G })
    local fnFile, err = loadfile(_sPath, nil, tEnv)
    if fnFile then
        local ok, err = pcall(fnFile, ...)
        if not ok then
            if err and err ~= "" then
                printError(err)
            end
            return false
        end
        return true
    end
    if err and err ~= "" then
        printError(err)
    end
    return false
end

function os.shutdown()
    nativeShutdown()
    while true do
        coroutine.yield()
    end
end

function os.reboot()
    nativeReboot()
    while true do
        coroutine.yield()
    end
end

if http then
    local nativeHTTPRequest = http.request

    local methods = {
        GET = true, POST = true, HEAD = true,
        OPTIONS = true, PUT = true, DELETE = true,
        PATCH = true, TRACE = true,
    }

    local function checkKey(options, key, ty, opt)
        local value = options[key]
        local valueTy = type(value)

        if (value ~= nil or not opt) and valueTy ~= ty then
            error(("bad field '%s' (expected %s, got %s"):format(key, ty, valueTy), 4)
        end
    end

    local function checkOptions(options, body)
        checkKey(options, "url", "string")
        if body == false then
          checkKey(options, "body", "nil")
        else
          checkKey(options, "body", "string", not body)
        end
        checkKey(options, "headers", "table", true)
        checkKey(options, "method", "string", true)
        checkKey(options, "redirect", "boolean", true)

        if options.method and not methods[options.method] then
            error("Unsupported HTTP method", 3)
        end
    end

    local function wrapRequest(_url, ...)
        local ok, err = nativeHTTPRequest(...)
        if ok then
            while true do
                local event, param1, param2, param3 = os.pullEvent()
                if event == "http_success" and param1 == _url then
                    return param2
                elseif event == "http_failure" and param1 == _url then
                    return nil, param2, param3
                end
            end
        end
        return nil, err
    end

    http.get = function(_url, _headers, _binary)
        if type(_url) == "table" then
            checkOptions(_url, false)
            return wrapRequest(_url.url, _url)
        end
        return wrapRequest(_url, _url, nil, _headers, _binary)
    end

    http.post = function(_url, _post, _headers, _binary)
        if type(_url) == "table" then
            checkOptions(_url, true)
            return wrapRequest(_url.url, _url)
        end
        return wrapRequest(_url, _url, _post, _headers, _binary)
    end

    http.request = function(_url, _post, _headers, _binary)
        local url
        if type(_url) == "table" then
            checkOptions(_url)
            url = _url.url
        else
            url = _url.url
        end

        local ok, err = nativeHTTPRequest(_url, _post, _headers, _binary)
        if not ok then
            os.queueEvent("http_failure", url, err)
        end
        return ok, err
    end

    local nativeCheckURL = http.checkURL
    http.checkURLAsync = nativeCheckURL
    http.checkURL = function(_url)
        local ok, err = nativeCheckURL(_url)
        if not ok then return ok, err end

        while true do
            local _, url, ok, err = os.pullEvent("http_check")
            if url == _url then return ok, err end
        end
    end

    local nativeWebsocket = http.websocket
    http.websocketAsync = nativeWebsocket
    http.websocket = function(_url, _headers)
        expect(1, _url, "string")
        expect(2, _headers, "table", "nil")

        local ok, err = nativeWebsocket(_url, _headers)
        if not ok then return ok, err end

        while true do
            local event, url, param = os.pullEvent( )
            if event == "websocket_success" and url == _url then
                return param
            elseif event == "websocket_failure" and url == _url then
                return false, param
            end
        end
    end
end

local tEmpty = {}
function fs.complete(sPath, sLocation, bIncludeFiles, bIncludeDirs)
    bIncludeFiles = bIncludeFiles ~= false
    bIncludeDirs = bIncludeDirs ~= false
    local sDir = sLocation
    local nStart = 1
    local nSlash = string.find(sPath, "[/\\]", nStart)
    if nSlash == 1 then
        sDir = ""
        nStart = 2
    end
    local sName
    while not sName do
        local nSlash = string.find(sPath, "[/\\]", nStart)
        if nSlash then
            local sPart = string.sub(sPath, nStart, nSlash - 1)
            sDir = fs.combine(sDir, sPart)
            nStart = nSlash + 1
        else
            sName = string.sub(sPath, nStart)
        end
    end

    if fs.isDir(sDir) then
        local tResults = {}
        if bIncludeDirs and sPath == "" then
            table.insert(tResults, ".")
        end
        if sDir ~= "" then
            if sPath == "" then
                table.insert(tResults, bIncludeDirs and ".." or "../")
            elseif sPath == "." then
                table.insert(tResults, bIncludeDirs and "." or "./")
            end
        end
        local tFiles = fs.list(sDir)
        for n = 1, #tFiles do
            local sFile = tFiles[n]
            if #sFile >= #sName and string.sub(sFile, 1, #sName) == sName then
                local bIsDir = fs.isDir(fs.combine(sDir, sFile))
                local sResult = string.sub(sFile, #sName + 1)
                if bIsDir then
                    table.insert(tResults, sResult .. "/")
                    if bIncludeDirs and #sResult > 0 then
                        table.insert(tResults, sResult)
                    end
                else
                    if bIncludeFiles and #sResult > 0 then
                        table.insert(tResults, sResult)
                    end
                end
            end
        end
        return tResults
    end
    return tEmpty
end

function fs.isDriveRoot(sPath)
    return fs.getDir(sPath) == ".." or fs.getDrive(sPath) ~= fs.getDrive(fs.getDir(sPath))
end

local details, values = {}, {}


local function serializeImpl(t, tTracking, sIndent)
    local sType = type(t)
    if sType == "table" then
        if tTracking[t] ~= nil then
            error("Cannot serialize table with recursive entries", 0)
        end
        tTracking[t] = true

        if next(t) == nil then
            -- Empty tables are simple
            return "{}"
        else
            -- Other tables take more work
            local sResult = "{\n"
            local sSubIndent = sIndent .. "  "
            local tSeen = {}
            for k, v in ipairs(t) do
                tSeen[k] = true
                sResult = sResult .. sSubIndent .. serializeImpl(v, tTracking, sSubIndent) .. ",\n"
            end
            for k, v in pairs(t) do
                if not tSeen[k] then
                    local sEntry
                    if type(k) == "string" and not g_tLuaKeywords[k] and string.match(k, "^[%a_][%a%d_]*$") then
                        sEntry = k .. " = " .. serializeImpl(v, tTracking, sSubIndent) .. ",\n"
                    else
                        sEntry = "[ " .. serializeImpl(k, tTracking, sSubIndent) .. " ] = " .. serializeImpl(v, tTracking, sSubIndent) .. ",\n"
                    end
                    sResult = sResult .. sSubIndent .. sEntry
                end
            end
            sResult = sResult .. sIndent .. "}"
            return sResult
        end

    elseif sType == "string" then
        return string.format("%q", t)

    elseif sType == "number" or sType == "boolean" or sType == "nil" then
        return tostring(t)

    else
        error("Cannot serialize type " .. sType, 0)

    end
end

function textutils.serialize(t)
    local tTracking = {}
    return serializeImpl(t, tTracking, "")
end

function textutils.unserialize(s)
    expect(1, s, "string")
    local func = load("return " .. s, "unserialize", "t", {})
    if func then
        local ok, result = pcall(func)
        if ok then
            return result
        end
    end
    return nil
end

local function field(tbl, index, ...)
    local value = tbl[index]
    local t = native_type(value)
    for i = 1, native_select("#", ...) do
        if t == native_select(i, ...) then return value end
    end

    if value == nil then
        error(("field '%s' missing from table"):format(index), 3)
    else
        error(("bad field '%s' (expected %s, got %s)"):format(index, get_type_names(...), t), 3)
    end
end

function settings.reserialize(value)
    if type(value) ~= "table" then return value end
    return textutils.unserialize(textutils.serialize(value))
end

function settings.copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for k, v in pairs(value) do result[k] = copy(v) end
    return result
end

local valid_types = { "number", "string", "boolean", "table" }
for _, v in ipairs(valid_types) do valid_types[v] = true end

function settings.define(name, options)
    if options then
        options = {
            description = field(options, "description", "string", "nil"),
            default = reserialize(field(options, "default", "number", "string", "boolean", "table", "nil")),
            type = field(options, "type", "string", "nil"),
        }

        if options.type and not valid_types[options.type] then
            error(("Unknown type %q. Expected one of %s."):format(options.type, table.concat(valid_types, ", ")), 2)
        end
    else
        options = {}
    end

    details[name] = options
end

function settings.undefine(name)
    details[name] = nil
end

function settings.set_value(name, value)
    local new = reserialize(value)
    local old = values[name]
    if old == nil then
        local opt = details[name]
        old = opt and opt.default
    end

    values[name] = new
    if old ~= new then
        os.queueEvent("setting_changed", name, new, old)
    end
end

function settings.set(name, value)
    local opt = details[name]
    if opt and opt.type then expect(2, value, opt.type) end

    set_value(name, value)
end

function settings.get(name, default)
    local result = values[name]
    if result ~= nil then
        return copy(result)
    elseif default ~= nil then
        return default
    else
        local opt = details[name]
        return opt and copy(opt.default)
    end
end

function settings.getDetails(name)
    local deets = copy(details[name]) or {}
    deets.value = values[name]
    deets.changed = deets.value ~= nil
    if deets.value == nil then deets.value = deets.default end
    return deets
end

function settings.unset(name)
    set_value(name, nil)
end

function settings.clear()
    for name in pairs(values) do
        set_value(name, nil)
    end
end

function settings.getNames()
    local result, n = {}, 1
    for k in pairs(details) do
        result[n], n = k, n + 1
    end
    for k in pairs(values) do
        if not details[k] then result[n], n = k, n + 1 end
    end
    table.sort(result)
    return result
end

function settings.load(sPath)
    local file = fs.open(sPath or ".settings", "r")
    if not file then
        return false
    end

    local sText = file.readAll()
    file.close()

    local tFile = textutils.unserialize(sText)
    if type(tFile) ~= "table" then
        return false
    end

    for k, v in pairs(tFile) do
        local ty_v = type(v)
        if type(k) == "string" and (ty_v == "string" or ty_v == "number" or ty_v == "boolean" or ty_v == "table") then
            local opt = details[k]
            if not opt or not opt.type or ty_v == opt.type then
                set_value(k, v)
            end
        end
    end

    return true
end

function settings.save(sPath)
    local file = fs.open(sPath or ".settings", "w")
    if not file then
        return false
    end

    file.write(textutils.serialize(values))
    file.close()

    return true
end

settings.define("bios.loadAPI", {
    default = true,
    description = "Load the APIs stored in /api/",
    type = "boolean",
})

if fs.exists(".settings") then
    settings.load(".settings")
end
    
if settings.get("bios.loadAPI") == true then
    local files = fs.list("/api")
    for i,v in ipairs(files) do
        dofile("/api/"..v)
    end
end

sleep(5)
