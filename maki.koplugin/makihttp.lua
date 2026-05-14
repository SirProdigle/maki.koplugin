--[[--
Maki HTTP client with HTTP/1.1 keep-alive.

The default `socket.http.request` closes the TCP socket after each call —
which means a fresh TLS handshake for every download. On an underpowered
Kindle radio, that handshake is a meaningful chunk of the per-file time.

This module manages one socket (TCP + LuaSec) per client instance and
issues serial `GET`s over it. Falls back gracefully if the server hangs up
between requests; on a bad request the connection is closed and reopened
on the next call.

Only what maki needs: HTTPS, GET, HTTP Basic auth, single host. Bodies
written straight to disk. No keep-alive timer juggling — we rely on
"Connection: keep-alive" + the server's idle timeout (Komga / Spring
defaults to 60s; serial downloads keep the socket warm well under that).
--]]

local socket = require("socket")
local socket_url = require("socket.url")
local mime = require("mime")

local DEFAULT_CONNECT_TIMEOUT = 10
local DEFAULT_IO_TIMEOUT      = 60
local READ_CHUNK              = 32 * 1024

local Client = {}
Client.__index = Client

-- base_url: e.g. "https://komga.bussybox.live"
-- username/password (optional): used for HTTP Basic auth on every request
function Client:new(opts)
    local parsed = socket_url.parse(opts.base_url or "")
    if parsed.scheme ~= "https" then
        return nil, "makihttp: only https is supported (got " .. tostring(parsed.scheme) .. ")"
    end
    local o = setmetatable({}, self)
    o.host        = parsed.host
    o.port        = tonumber(parsed.port) or 443
    o.username    = opts.username
    o.password    = opts.password
    o.user_agent  = opts.user_agent or "maki.koplugin"
    o.sock        = nil
    o.connect_to  = opts.connect_timeout or DEFAULT_CONNECT_TIMEOUT
    o.io_to       = opts.io_timeout or DEFAULT_IO_TIMEOUT
    if opts.username and opts.password then
        o.auth_header = "Basic " .. (mime.b64(opts.username .. ":" .. opts.password))
    end
    return o
end

local function safe_close(sock)
    if sock then pcall(function() sock:close() end) end
end

function Client:_connect()
    local sock = socket.tcp()
    sock:settimeout(self.connect_to)
    local ok, err = sock:connect(self.host, self.port)
    if not ok then
        safe_close(sock)
        return nil, "connect: " .. tostring(err)
    end

    local ssl = require("ssl")
    local params = {
        mode     = "client",
        protocol = "any",
        verify   = "none",  -- KOReader's existing ssl.https path also doesn't verify
        options  = "all",
    }
    local wrapped, werr = ssl.wrap(sock, params)
    if not wrapped then
        safe_close(sock)
        return nil, "ssl wrap: " .. tostring(werr)
    end
    -- SNI for virtual-hosted servers like Caddy/nginx in front of Komga
    if wrapped.sni then wrapped:sni(self.host) end
    wrapped:settimeout(self.io_to)
    local ok2, err2 = wrapped:dohandshake()
    if not ok2 then
        safe_close(wrapped)
        return nil, "tls handshake: " .. tostring(err2)
    end
    self.sock = wrapped
    return true
end

function Client:close()
    safe_close(self.sock)
    self.sock = nil
end

-- Read a CRLF-terminated line (without the CRLF) from the socket.
local function recv_line(sock)
    local line, err = sock:receive("*l")
    return line, err
end

-- Read headers until empty line. Lowercases keys. Returns table, or nil + err.
local function recv_headers(sock)
    local h = {}
    while true do
        local line, err = recv_line(sock)
        if not line then return nil, err end
        if line == "" then return h end
        local k, v = line:match("^([^:]+):%s*(.*)$")
        if k then h[k:lower()] = v end
    end
end

-- Reads `n` bytes from sock and writes them straight to `out_file`. Returns
-- bytes_written, or nil + err on a hard failure mid-stream.
local function pipe_n(sock, out_file, n)
    local written = 0
    while written < n do
        local want = math.min(READ_CHUNK, n - written)
        local data, err, partial = sock:receive(want)
        local chunk = data or partial
        if chunk and #chunk > 0 then
            out_file:write(chunk)
            written = written + #chunk
        end
        if not data then
            -- timeout with partial is recoverable; anything else is fatal.
            if err and err ~= "timeout" then
                return nil, err
            end
            if not partial then
                return nil, err or "short read"
            end
        end
    end
    return written
end

-- Read a chunked-transfer body to out_file.
local function pipe_chunked(sock, out_file)
    while true do
        local size_line, err = recv_line(sock)
        if not size_line then return nil, "chunk size: " .. tostring(err) end
        -- "1f" or "1f;ext=..."
        local hex = size_line:match("^(%x+)")
        if not hex then return nil, "bad chunk size: " .. size_line end
        local size = tonumber(hex, 16)
        if size == 0 then
            -- read trailing headers (probably empty) until blank line
            while true do
                local trailer = recv_line(sock)
                if not trailer or trailer == "" then break end
            end
            return true
        end
        local ok, perr = pipe_n(sock, out_file, size)
        if not ok then return nil, perr end
        -- CRLF after the chunk data
        sock:receive(2)
    end
end

-- GET `path` (e.g. "/opds/v1.2/books/.../file/x.cbz"), writing the response
-- body to `out_path`. Returns true on success, false + reason on failure.
-- If the connection is closed by the server mid-session, the next call
-- transparently reopens.
function Client:download(path, out_path)
    -- Ensure connection
    if not self.sock then
        local ok, err = self:_connect()
        if not ok then return false, err end
    end

    -- Compose request
    local req_lines = {
        "GET " .. path .. " HTTP/1.1",
        "Host: " .. self.host,
        "User-Agent: " .. self.user_agent,
        "Accept: */*",
        "Accept-Encoding: identity",
        "Connection: keep-alive",
    }
    if self.auth_header then
        table.insert(req_lines, "Authorization: " .. self.auth_header)
    end
    local req = table.concat(req_lines, "\r\n") .. "\r\n\r\n"

    local _, send_err = self.sock:send(req)
    if send_err then
        -- Likely a stale half-closed connection. Reopen and try once.
        self:close()
        local rok, rerr = self:_connect()
        if not rok then return false, "reconnect: " .. tostring(rerr) end
        local _, send_err2 = self.sock:send(req)
        if send_err2 then return false, "send: " .. tostring(send_err2) end
    end

    -- Status line
    local status_line, sl_err = recv_line(self.sock)
    if not status_line then
        self:close()
        return false, "no status: " .. tostring(sl_err)
    end
    local code = tonumber(status_line:match("HTTP/1%.[01]%s+(%d+)"))
    if not code then
        self:close()
        return false, "bad status: " .. status_line
    end

    local headers, herr = recv_headers(self.sock)
    if not headers then
        self:close()
        return false, "headers: " .. tostring(herr)
    end

    if code ~= 200 then
        -- Drain body so the next request can use the connection.
        local cl = tonumber(headers["content-length"])
        if cl and cl > 0 then
            local devnull = { write = function() end, close = function() end }
            pipe_n(self.sock, devnull, cl)
        end
        if headers["connection"] and headers["connection"]:lower() == "close" then
            self:close()
        end
        return false, "http " .. code
    end

    local f, ferr = io.open(out_path, "wb")
    if not f then
        self:close()
        return false, "open: " .. tostring(ferr)
    end

    local ok
    local cl = tonumber(headers["content-length"])
    if cl then
        ok = pipe_n(self.sock, f, cl)
    elseif headers["transfer-encoding"] and headers["transfer-encoding"]:lower():find("chunked") then
        ok = pipe_chunked(self.sock, f)
    else
        -- No length and no chunked → server will close after body. We can't
        -- keepalive after this, so we read until close and then drop the sock.
        repeat
            local data, err, partial = self.sock:receive(READ_CHUNK)
            local chunk = data or partial
            if chunk and #chunk > 0 then f:write(chunk) end
            if not data then
                ok = err == "closed" and true or nil
                break
            end
        until false
        self:close()
    end
    f:close()

    if not ok then
        -- Partial file is more confusing than no file.
        pcall(os.remove, out_path)
        self:close()
        return false, "body read failed"
    end

    if headers["connection"] and headers["connection"]:lower() == "close" then
        self:close()
    end
    return true
end

-- Convenience: download an absolute URL through this client iff the host
-- matches; returns nil if it doesn't (caller should fall back).
function Client:downloadURL(absolute_url, out_path)
    local p = socket_url.parse(absolute_url or "")
    if p.scheme ~= "https" or p.host ~= self.host
       or (tonumber(p.port) or 443) ~= self.port then
        return nil, "host mismatch"
    end
    local path = p.path or "/"
    if p.query and p.query ~= "" then path = path .. "?" .. p.query end
    return self:download(path, out_path)
end

return { Client = Client }
