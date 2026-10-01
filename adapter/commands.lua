--- Every name a player can type or press, in one place.
--
-- There were two places. A table of chat commands in `adapter/client.lua`, and
-- four `RegisterCommand` calls in `adapter/nui.lua`, and nothing compared them.
-- Both claimed `nyrpockets` -- the chat row that prints what you are carrying,
-- and the F3 screen that draws it -- so the game said "Command nyrpockets is
-- already registered." on every client start, only one handler survived, and
-- which one depended on the order `fxmanifest.lua` happens to list the files
-- in. The text formatter for `me.pockets` in client.lua had never run once.
--
-- Neither of those files can be loaded by the spec suite, so nothing could
-- hold the two lists apart. This one can be loaded, so the names live here and
-- `spec/player_commands_spec.lua` holds them apart -- the same split as
-- `NuiState.follow_up` and `DevBridge.act_plan`: the decision where a spec can
-- reach it, the native call left in the adapter.

local Commands = {}

-- --------------------------------------------------------------- typed

--- One table rather than fifty hand-written registrations. Each row is a chat
--- command, the server command it asks for, and the arguments it takes in
--- order. A name ending in `:int` is converted to a whole number; one ending in
--- `:money` is typed in dollars and sent as whole cents; one ending in `:rest`
--- takes everything remaining, which is what a message body or a reason needs.
--- An argument the player leaves out is simply not sent, and the server's own
--- declaration decides whether that was allowed. `Commands.args` does the
--- converting.
Commands.TYPED = {
    -- who you are
    { "nyrcreate",   "character.create",  { "first_name", "last_name" } },
    { "nyrplay",     "character.select",  { "character" } },
    { "nyrleave",    "character.release", {} },
    { "nyrretire",   "character.retire",  { "character" } },
    { "nyrme",       "me.status",         {} },
    -- Not `nyrpockets`: that name belongs to the F3 screen in nui.lua, and
    -- when both claimed it the game kept one handler and the other silently
    -- never ran. The formatter for `me.pockets` below had never once been
    -- reached. See `PRESSED`.
    { "nyrcarry",    "me.pockets",        {} },
    { "nyrrecord",   "record.mine",       {} },

    -- carrying things
    { "nyrmove",     "inventory.move",    { "from", "to", "item", "count:int" } },
    { "nyrdrop",     "inventory.drop",    { "item", "count:int" } },
    { "nyruse",      "inventory.use",     { "item" } },

    -- earning
    -- The read comes first here because it does in play too: nothing else in
    -- the city ever names an employer, so without this there is no id to put
    -- in the next line.
    { "nyrjobs",     "work.list",         {} },
    { "nyrwork",     "work.start",        { "employer", "job" } },
    { "nyrclockoff", "work.finish",       {} },
    { "nyrquit",     "work.abandon",      {} },

    -- living somewhere
    { "nyrbuy",      "property.buy",      { "place" } },
    { "nyrlist",     "property.list",     { "place", "price:money" } },
    { "nyrenter",    "property.enter",    { "place" } },
    { "nyrkey",      "property.key",      { "place", "holder" } },
    { "nyrsettle",   "property.settle",   { "place" } },

    -- driving
    { "nyrtake",     "vehicle.take",      { "vehicle" } },
    { "nyrstore",    "vehicle.store",     { "vehicle" } },
    { "nyrboot",     "vehicle.boot",      { "vehicle" } },
    { "nyrvkey",     "vehicle.key",       { "vehicle", "holder" } },
    { "nyrhotwire",  "vehicle.hotwire",   { "vehicle" } },
    { "nyrcollect",  "vehicle.retrieve",  { "vehicle" } },

    -- money
    { "nyropen",     "bank.open",         { "branch" } },
    { "nyrdeposit",  "bank.deposit",      { "branch", "amount:money" } },
    { "nyrwithdraw", "bank.withdraw",     { "branch", "amount:money" } },
    { "nyrsend",     "bank.transfer",     { "to", "amount:money", "reference:rest" } },
    { "nyrbank",     "bank.statement",    {} },

    -- shopping, and the other kind
    { "nyrshop",     "shop.list",         { "shop" } },
    { "nyrshopbuy",  "shop.buy",          { "shop", "item", "count:int" } },
    { "nyrshopsell", "shop.sell",         { "shop", "item", "count:int" } },
    { "nyrrob",      "shop.rob",          { "shop" } },
    { "nyrfence",    "fence.list",        { "fence" } },
    { "nyrfencesell","fence.sell",        { "fence", "item", "count:int" } },
    { "nyrchop",     "fence.chop",        { "fence", "vehicle" } },

    -- being hurt
    { "nyrrevive",   "health.revive",     { "target" } },
    { "nyrrespawn",  "health.respawn",    {} },

    -- crews
    { "nyrcrew",     "gang.roster",       {} },
    { "nyrinvite",   "gang.invite",       { "target" } },
    { "nyrjoin",     "gang.join",         { "crew" } },
    { "nyrpart",     "gang.leave",        {} },
    { "nyrkick",     "gang.kick",         { "target" } },
    { "nyrrank",     "gang.promote",      { "target", "rank:int" } },
    { "nyrcrewin",   "gang.deposit",      { "amount:money" } },
    { "nyrcrewout",  "gang.withdraw",     { "amount:money" } },
    { "nyrclaim",    "gang.claim",        { "turf" } },

    -- the phone
    { "nyrnumber",   "phone.number",      {} },
    { "nyrtext",     "phone.send",        { "to", "body:rest" } },
    { "nyrthread",   "phone.thread",      { "with" } },
    { "nyrinbox",    "phone.inbox",       {} },

    -- the job
    { "nyrduty",     "police.duty",       {} },
    { "nyrarrest",   "police.arrest",     { "suspect" } },
    { "nyrlookup",   "police.lookup",     { "suspect" } },
    { "nyrseize",    "police.seize",      { "vehicle" } },
    { "nyrmdt",      "mdt.messages",      { "number" } },

    -- staff
    { "nyrwho",      "admin.who",         {} },
    { "nyrlook",     "admin.look",        { "character" } },
    { "nyrgive",     "admin.give",        { "character", "amount:money", "reason:rest" } },
    { "nyrtakecash", "admin.take",        { "character", "amount:money", "reason:rest" } },
    { "nyrmake",     "admin.item",        { "character", "item", "count:int", "reason:rest" } },
    { "nyrtrail",    "admin.trail",       {} },}

--- What the words a player typed become, for one row's arguments.
---
--- Returns the arguments to send, or nil and a line to show. This was
--- `build_args` in `adapter/client.lua`, where no spec could load it, and it read
--- every amount as a whole number of cents: `/nyrlist <place> 3000` put a flat on
--- the market for $30.00 and a buyer paid that, while the bank screen had been
--- reading dollars for two days. Money goes through `ClientState.cents`, the
--- screen's own reading, so the two cannot drift apart again.
function Commands.args(spec, words)
    local args, position = {}, 1
    for _, field in ipairs(spec) do
        local name, kind = field:match("^([^:]+):?(.*)$")
        if kind == "rest" then
            if words[position] then
                args[name] = table.concat(words, " ", position)
            end
            break
        end
        local word = words[position]
        position = position + 1
        if word ~= nil then
            if kind == "int" then
                local number = math.tointeger(tonumber(word))
                if number == nil then
                    return nil, ("%s has to be a whole number"):format(name)
                end
                args[name] = number
            elseif kind == "money" then
                -- Reached for here rather than at the top: the server loads
                -- this file for the allowlist and has no use for the client's
                -- reading of money.
                local ClientState = NyrClientState or require("adapter.client_state")
                local amount = ClientState.cents(word)
                if amount == nil then
                    return nil, ("%s has to be an amount of money, like 200 or 12.50"):format(name)
                end
                args[name] = amount
            else
                args[name] = word
            end
        end
    end
    return args
end

-- ------------------------------------------------------------- pressed

--- A key opens a drawn screen. Each row is the command the key runs, the
--- screen it opens, the line a player reads in the game's key settings, and
--- the default key.
---
--- The command name is what FiveM remembers a rebinding against, so it is not
--- a name to change for tidiness: a player who moved this to another key loses
--- that when it is renamed. That is why the clash above was settled by moving
--- the chat row and not this one.
Commands.PRESSED = {
    { "nyrpicker",  "picker",  "NYR: who are you today",     "F2" },
    { "nyrpockets", "pockets", "NYR: what you are carrying", "F3" },
    { "nyrphone",   "phone",   "NYR: your phone",            "F4" },
    { "nyrnearby",  "nearby",  "NYR: what is around you",    "F5" },
    -- Work has no location: an employer is external and there is nowhere to
    -- stand, so the only way to reach a job board is a key. A bank is a place
    -- and opens by walking to it, which is why it is not here.
    { "nyrboard",   "jobs",    "NYR: who is hiring",         "F6" },
}

--- Registered by `adapter/client.lua` on their own, outside the table. They
--- are named here so that what claims a name and what checks for a clash are
--- the same list.
Commands.ALSO = { "nyrhelp", "nyrhud" }

-- ------------------------------------------------------------- allowed

--- What the server will accept from a client, and nothing else.
---
--- A second gate, deliberately hand-kept: a command reaching this list is a
--- decision that an untrusted client may ask for it, so it is not derived from
--- the tables above. Deriving it would mean that adding a chat command quietly
--- widened what the server accepts, which is the opposite of the point.
---
--- Hand-kept is not unchecked. Twice now a command has been defined, reachable
--- from the client, and absent from here -- the first time the picker asked,
--- was refused, and drew a black screen; the second time `/nyrjobs` was
--- refused as something you cannot ask for while the command worked. Both were
--- one absent line. `spec/player_commands_spec.lua` now reads this list
--- against the two above.
Commands.ALLOWED = {

    -- The first read a player makes, before they are anybody. It was
    -- missing, and a command that is not on this list is refused however
    -- valid it is -- so the picker asked, was refused, and drew nothing.
    -- A black screen, from one absent line.
    "character.list",
    "character.create",
    "character.select",
    "character.release",
    "character.retire",
    "inventory.look",
    "inventory.move",
    "inventory.drop",
    "inventory.use",
    -- `work.list` was added with `/nyrjobs` and not added here, so a player
    -- who typed it was told "That is not something you can ask for" while the
    -- command sat defined and working on the server. Exactly the failure the
    -- note at the top of this list describes, in the same week.
    "work.list",
    "work.start",
    "work.finish",
    "work.abandon",
    "property.buy",
    "property.list",
    "property.enter",
    "property.key",
    "property.settle",
    "vehicle.take",
    "vehicle.store",
    "vehicle.boot",
    "vehicle.key",
    "vehicle.hotwire",
    "vehicle.retrieve",
    "police.duty",
    "police.arrest",
    "police.lookup",
    "police.seize",
    "bank.open",
    "bank.deposit",
    "bank.withdraw",
    "bank.transfer",
    "bank.statement",
    "shop.list",
    "shop.buy",
    "shop.sell",
    "shop.rob",
    "health.status",
    "health.revive",
    "health.respawn",
    "gang.roster",
    "gang.invite",
    "gang.join",
    "gang.leave",
    "gang.kick",
    "gang.promote",
    "gang.deposit",
    "gang.withdraw",
    "gang.claim",
    "phone.number",
    "phone.send",
    "phone.thread",
    "phone.inbox",
    "mdt.messages",
    "fence.list",
    "fence.sell",
    "fence.chop",
    "admin.who",
    "admin.look",
    "admin.give",
    "admin.take",
    "admin.item",
    "admin.trail",
    "me.status",
    "me.pockets",
    "me.nearby",
    -- Where things are, so a client can mark them. Asked once on spawn.
    "me.map",
    "record.mine",
}

-- -------------------------------------------------------------- checking

--- Every name the client claims, and what claims it.
function Commands.claimed()
    local out = {}
    local function claim(name, by)
        out[name] = out[name] or {}
        table.insert(out[name], by)
    end
    for _, row in ipairs(Commands.TYPED) do claim(row[1], "typed") end
    for _, row in ipairs(Commands.PRESSED) do claim(row[1], "pressed") end
    for _, name in ipairs(Commands.ALSO) do claim(name, "also") end
    return out
end

--- Any name claimed more than once, sorted.
---
--- Empty is the only acceptable answer. FiveM keeps one handler per name, so a
--- clash is not two things happening -- it is one of them silently not
--- happening, chosen by load order.
function Commands.clashes()
    local found = {}
    for name, by in pairs(Commands.claimed()) do
        if #by > 1 then
            table.sort(by)
            found[#found + 1] = { name = name, by = by }
        end
    end
    table.sort(found, function(a, b) return a.name < b.name end)
    return found
end

--- Anything a player can reach that the server will not accept.
---
--- `also` is anything else that asks through the same bridge, as
--- `{ how = "...", command = "..." }` -- the drawn interface's declared
--- actions, which live in `nui_state` and are passed in rather than reached
--- for, so that nothing on the server has to load a view builder.
---
--- The looking happens here, not in the spec. It was written in the spec
--- first, in a loop of its own, and the test that proved the check works had
--- its own second copy of that loop: breaking the real one changed nothing and
--- both tests passed. A check tested against a copy of itself is not tested.
function Commands.unreachable(also)
    local allowed = {}
    for _, name in ipairs(Commands.ALLOWED) do allowed[name] = true end

    local out = {}
    for _, row in ipairs(Commands.TYPED) do
        if not allowed[row[2]] then
            out[#out + 1] = { how = "/" .. row[1], command = row[2] }
        end
    end
    for _, row in ipairs(also or {}) do
        if not allowed[row.command] then
            out[#out + 1] = { how = row.how, command = row.command }
        end
    end
    table.sort(out, function(a, b) return a.how < b.how end)
    return out
end

NyrCommands = Commands

return Commands
