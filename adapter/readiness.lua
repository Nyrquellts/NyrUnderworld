--- Bounded asynchronous transport gate, not gameplay authorization.
local Readiness = {}
Readiness.__index = Readiness
function Readiness.new(opts)
    opts = opts or {}
    return setmetatable({ now = opts.now or function() return 0 end,
        timeout = opts.timeout or 15000, limit = opts.limit or 64,
        on_reset = opts.on_reset or function() end, queue = {}, stable = 0,
        ready = false, blocked = false, stopped = false, session = nil, generation = 0 }, Readiness)
end
local function outcome(code)
    return { ok = false, code = code, message = "The world is not ready. Please try again once it has loaded." }
end
function Readiness:reset(code)
    self.ready, self.stable = false, 0
    self.generation = self.generation + 1
    local old = self.queue; self.queue = {}
    for _, request in ipairs(old) do pcall(request.fail, outcome(code or "world_changed")) end
    pcall(self.on_reset, outcome(code or "world_changed"))
end
function Readiness:set_session(session)
    if type(session) ~= "string" or session == "" or #session > 128 then return false end
    if self.session and self.session ~= session then self:reset("server_restarted") end
    self.session = session
    return true
end
function Readiness:suspend()
    if self.blocked or self.stopped then return nil end
    self.blocked = true
    self:reset("world_relocating")
    self.lease = { generation = self.generation, session = self.session }
    return self.lease
end
function Readiness:current(lease)
    return lease ~= nil and self.lease == lease and lease.generation == self.generation
        and lease.session == self.session and not self.stopped
end
function Readiness:release(lease)
    if not lease or lease ~= self.lease then return false end
    self.lease = nil; self.blocked = false; self.stable = 0
    return true
end
function Readiness:stop()
    self.stopped = true; self.session = nil
    self:reset("resource_stopped")
end
function Readiness:submit(send, fail)
    if self.stopped then pcall(fail, outcome("resource_stopped")); return false end
    if self.ready then
        local ok = pcall(send, self.session, self.generation)
        if not ok then pcall(fail, outcome("dispatch_failed")) end
        return ok
    end
    if #self.queue + (self.reserved or 0) >= self.limit then pcall(fail, outcome("world_queue_full")); return false end
    self.queue[#self.queue + 1] = { send = send, fail = fail, at = self.now() }
    return true
end
function Readiness:observe(facts)
    if self.observing then return self.ready end
    self.observing = true
    local now = self.now()
    local expiring, generation = self.queue, self.generation
    self.queue = {}; self.reserved = #expiring
    for _, request in ipairs(expiring) do
        self.reserved = self.reserved - 1
        local elapsed = now - request.at
        if self.generation ~= generation then pcall(request.fail, outcome("world_changed"))
        elseif elapsed < 0 or elapsed >= self.timeout then pcall(request.fail, outcome("world_timeout"))
        else self.queue[#self.queue + 1] = request end
    end
    self.reserved = 0
    local usable = not self.stopped and not self.blocked and self.session ~= nil
        and facts.network == true and facts.ped == true and facts.collision == true
        and facts.loading == false and facts.switching == false
    if not usable then
        if self.ready then self:reset("world_unavailable") end
        self.stable = 0
        self.observing = false
        return false
    end
    self.stable = self.stable + 1
    if self.stable < 2 then self.observing = false; return false end
    self.ready = true
    local pending = self.queue; self.queue = {}; generation = self.generation
    for _, request in ipairs(pending) do
        if not self.ready or self.generation ~= generation then pcall(request.fail, outcome("world_changed"))
        else
            local ok = pcall(request.send, self.session, self.generation)
            if not ok then pcall(request.fail, outcome("dispatch_failed")) end
        end
    end
    self.observing = false
    return self.ready
end
function Readiness.copy(value, depth, seen)
    depth, seen = depth or 0, seen or {}
    if depth > 24 then error("request arguments exceed nesting limit") end
    if type(value) ~= "table" then
        if type(value) == "function" or type(value) == "userdata" or type(value) == "thread" then error("unsupported request argument") end
        return value
    end
    if seen[value] then error("cyclic request arguments") end
    seen[value] = true
    local out, count = {}, 0
    for key, item in pairs(value) do
        count = count + 1
        if count > 1024 or (type(key) ~= "string" and type(key) ~= "number") then error("invalid request arguments") end
        out[key] = Readiness.copy(item, depth + 1, seen)
    end
    seen[value] = nil
    return out
end
NyrReadiness = Readiness
return Readiness
