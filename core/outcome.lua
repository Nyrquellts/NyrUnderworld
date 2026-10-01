--- What happened, in a shape every caller can read.
--
-- Three things can come out of asking the simulation to do something, and
-- flattening them into one boolean is how a server ends up logging a player
-- being short of cash at the same volume as a crash.
--
--   ok        it happened. There may be a value.
--   refused   it did not happen, and that is a normal answer. The player could
--             not afford it, does not own it, is not in the gang, is too far
--             away. A code the interface can switch on, and a sentence a
--             person can read.
--   failed    it did not happen because something is broken. This one is a bug
--             report, and it is the only one that belongs in an error channel.
--
-- A refusal is never an error, and a failure is never shown to a player as if
-- they did something wrong.

local Outcome = {}
Outcome.__index = Outcome

local function build(ok, code, message, extra)
    -- Written out rather than `extra and extra.value or nil`, which answers nil
    -- for a value of `false`: a command whose answer is "no" would have told the
    -- client nothing at all.
    local value, details, events
    if extra ~= nil then
        value, details, events = extra.value, extra.details, extra.events
    end
    local outcome = setmetatable({
        ok = ok,
        code = code,
        message = message,
        value = value,
        details = details,
        events = events,
    }, Outcome)
    return outcome
end

function Outcome.ok(value, extra)
    return build(true, "ok", nil, { value = value, events = extra and extra.events,
        details = extra and extra.details })
end

--- A normal no. `code` is for the interface, `message` is for the person.
function Outcome.refused(code, message, details)
    assert(type(code) == "string" and code ~= "", "a refusal needs a code the interface can read")
    return build(false, code, message or code, { details = details })
end

--- Something is broken. Never shown to a player as their mistake.
function Outcome.failed(message, details)
    return build(false, "failed", message or "something went wrong", { details = details })
end

function Outcome.is(value)
    return getmetatable(value) == Outcome
end

function Outcome:succeeded() return self.ok == true end
function Outcome:was_refused() return self.ok == false and self.code ~= "failed" end
function Outcome:is_failure() return self.code == "failed" end

--- A plain table, for a log line, a client reply or a test fixture. The events
--- are named rather than carried, because a client has no business reading the
--- payload of every domain event a command produced.
---
--- `value` is carried, and leaving it out was the most expensive defect in this
--- project. This is the only shape a client ever receives -- `adapter/bridge.lua`
--- sends exactly this and nothing else -- and every screen in the interface is
--- drawn from `outcome.value`. Without it the whole interface came up blank on a
--- real client: pockets said "nothing" while the server held a phone, the picker
--- drew nobody, and `NuiState.follow_up` could not read the id of the character
--- just created, so a new player made somebody and was then unable to be them.
---
--- None of that failed a spec. The suite calls `world:dispatch` and reads
--- `.value` off the Outcome object itself, so it never crosses this boundary,
--- and every fake it hands the client was more generous than the real bridge.
--- The rule that came out of it: **a test that does not go through the shape
--- the other side actually receives is testing a shape nobody ships.**
---
--- A value is the result of a command this account was allowed to run and is
--- already scoped by the handler that produced it, so it is the player's own
--- answer coming back, not a window into anybody else's.
function Outcome:summary()
    local names = {}
    for _, event in ipairs(self.events or {}) do names[#names + 1] = event.name end
    return {
        ok = self.ok,
        code = self.code,
        message = self.message,
        value = self.value,
        events = names,
    }
end

function Outcome:__tostring()
    if self.ok then
        return ("<ok%s>"):format(self.value ~= nil and " " .. tostring(self.value) or "")
    end
    return ("<%s %s>"):format(self.code, tostring(self.message))
end

return Outcome
