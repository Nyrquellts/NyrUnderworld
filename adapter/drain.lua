--- Close all adapter inputs before awaiting persistence. Never kill a writer.
local Drain = {}
Drain.__index = Drain
function Drain.new(opts)
    assert(opts.now and opts.busy and opts.close_input and opts.finish and opts.spawn)
    return setmetatable({ opts = opts, status = "IDLE", timeout = opts.timeout or 30000 }, Drain)
end
function Drain:begin()
    if self.status ~= "IDLE" then return false, self.status end
    self.started = self.opts.now()
    self.status = "WAITING"
    self.opts.close_input() -- synchronous, before any coroutine can yield
    return true, self.status
end
function Drain:expired()
    local elapsed = self.opts.now() - self.started
    return elapsed < 0 or elapsed >= self.timeout
end
function Drain:poll()
    if self.status ~= "WAITING" and self.status ~= "SAVING" then return self.status end
    if self:expired() then self.status = "UNKNOWN"; self.error = "drain timed out; a write may still be running"; return self.status end
    if self.status == "WAITING" and not self.opts.busy() then
        self.status = "SAVING"
        self.opts.spawn(function()
            local called, saved, failures = pcall(self.opts.finish)
            if self.status ~= "SAVING" then return end
            if self:expired() then
                self.status = "UNKNOWN"; self.error = "drain timed out; late completion is not a shutdown acknowledgement"
            elseif called and saved then self.status = "DRAINED"
            else self.status = "FAILED"; self.error = called and failures or saved end
        end)
    end
    return self.status
end
function Drain:report()
    return { status = self.status, safe_to_stop = self.status == "DRAINED", error = self.error }
end
return Drain
