function os.version()
  return "miniBIOS 0.0.dev-1"
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
    expect(1, sText, "string", "number")

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
