--- What the drawn interface is allowed to ask for, and what it is told back.
--
-- A NUI page is a browser inside the game. It is HTML and JavaScript on the
-- player's own machine, it has developer tools, and anybody who wants to can
-- open them and call any callback this resource registers with any payload
-- they like. **The page is the least trustworthy part of the client**, and the
-- client was already the untrusted half.
--
-- So the boundary between the page and the Lua that serves it gets the same
-- discipline as the boundary between the client and the server: a closed set
-- of declared actions, undeclared fields refused rather than ignored, and
-- types checked before anything is sent on. `ACTIONS` below is that
-- declaration and there is no path around it.
--
-- The other half of the rule is what goes back. A reply to the page carries
-- whether it worked and a line to show. **It never carries the refusal code.**
-- The page cannot branch on a code it is never given, which turns "show a
-- refusal as text rather than acting on it" from a convention somebody has to
-- remember into something the shape of the message enforces.
--
-- None of this is a native, so all of it is tested in the spec suite.

local ClientState = NyrClientState or require("adapter.client_state")

local NuiState = {}

-- A page field longer than this is not a name anybody typed, so it is refused
-- before it becomes an event payload. This is a guard against a page sending
-- absurd data, not a rule about names: what counts as a name is the server's
-- business and it checks its own.
local MAX_FIELD = 200

--- Everything the page may ask the server to do, and nothing else. Each field
--- is `"string"` (sent as typed) or `"id"` (an identifier the server parses).
--- An action that is not here has no callback registered for it, so there is
--- nothing to call, and `request` refuses it a second time anyway.
local ACTIONS = {
    create = { command = "character.create", fields = { first_name = "string", last_name = "string" } },
    select = { command = "character.select", fields = { character = "id" } },
    retire = { command = "character.retire", fields = { character = "id" } },
    -- Carrying things. `count` arrives as a string because a form field is a
    -- string; the server declares it an integer and refuses anything else, so
    -- it is converted here and the server still decides.
    drop = { command = "inventory.drop", fields = { item = "string", count = "integer" } },
    use = { command = "inventory.use", fields = { item = "string" } },
    -- The phone. There is no `from`: the sending number is the one the server
    -- wrote on this character, and a message that appears to come from
    -- somebody else is a way to get a person killed by their own crew.
    send = { command = "phone.send", fields = { to = "string", body = "string" } },
    thread = { command = "phone.thread", fields = { with = "string" } },
    -- A counter. The page never says what anything costs: it names the shop,
    -- the thing and how many, and the price is whatever the shop charges.
    shop = { command = "shop.list", fields = { shop = "id" } },
    buy = { command = "shop.buy", fields = { shop = "id", item = "string", count = "integer" } },
    sell = { command = "shop.sell", fields = { shop = "id", item = "string", count = "integer" } },
    -- Somewhere to put things down. `enter` is what grants reach to a stash;
    -- without it every move to one is refused, which is the point.
    enter = { command = "property.enter", fields = { place = "id" } },
    -- Somewhere to live. Named `purchase` because `buy` is the shop counter's
    -- and one name for two commands is how a page ends up asking the wrong one
    -- to spend money. The page names the door and nothing else: what it costs
    -- is what the city is asking, never what the page says it is asking.
    purchase = { command = "property.buy", fields = { place = "id" } },
    -- A counter at a bank. `branch` is the place, exactly as `shop` is for a
    -- till: the server decides whether somebody is standing at it, and the
    -- page names which one rather than claiming to be there.
    account = { command = "bank.open", fields = { branch = "id" } },
    -- `amount` is typed in dollars and sent as whole cents; see `cents` below.
    deposit = { command = "bank.deposit", fields = { branch = "id", amount = "money" } },
    withdraw = { command = "bank.withdraw", fields = { branch = "id", amount = "money" } },
    -- Work. The page names the employer and the job from the board it was
    -- given; what either is worth is the server's.
    clockon = { command = "work.start", fields = { employer = "id", job = "string" } },
    clockoff = { command = "work.finish", fields = {} },
    walkoff = { command = "work.abandon", fields = {} },
    stow = { command = "inventory.move", fields = { from = "string", to = "string",
                                                    item = "string", count = "integer" } },
}

NuiState.ACTIONS = ACTIONS

--- The price a door was drawn with, carried on its purchase.
---
--- property.buy refuses `price_changed` when the price named is not what the
--- city asks now, so a seller who put the price up between Around you being
--- drawn and Buy being pressed takes nothing. The page cannot name that price:
--- `purchase` declares a place and nothing else, and a page that sends a price
--- is refused. It comes from `nearby`, the answer Lua drew the screen from.
--- A door that answer did not offer for sale goes without one.
function NuiState.priced(action, args, nearby)
    if action ~= "purchase" or type(args) ~= "table" then return args end
    local places = type(nearby) == "table" and nearby.places or nil
    if type(places) ~= "table" then return args end
    for _, row in ipairs(places) do
        if type(row) == "table" and row.place == args.place and row.for_sale == true
            and math.type(row.price) == "integer" then
            local out = {}
            for field, value in pairs(args) do out[field] = value end
            out.price = row.price
            return out
        end
    end
    return args
end
NuiState.MAX_FIELD = MAX_FIELD

function NuiState.actions()
    local names = {}
    for name in pairs(ACTIONS) do names[#names + 1] = name end
    table.sort(names)
    return names
end

--- Money as a person reads it. The same formatter the rest of the interface
--- uses, named here so a view can reach it without knowing where it lives.
function NuiState.money(minor)
    return ClientState.money(minor)
end

local function trim(text)
    -- A literal space rather than %s: %s matches a newline, and a name that
    -- can contain one breaks every line it is printed on.
    return (text:gsub("^[ \t]+", ""):gsub("[ \t]+$", ""))
end

--- Dollars as a person types them, as whole cents, or nil. The reading is
--- `ClientState.cents`, shared with chat, so the bank screen and `/nyrdeposit`
--- cannot come to disagree about what 200 means.
local cents = ClientState.cents

--- Turn something the page asked for into a server request.
---
--- Returns `command, args` when the page asked for something it is allowed to
--- ask for, or `nil, reason` when it did not. The reason is a line to show,
--- because that is all the page ever gets.
---
--- Trimming surrounding spaces is a convenience for somebody typing into a
--- box. It is not a rule: whether `Jane` is a name is decided by the server,
--- which checks its own pattern and refuses in its own words.
function NuiState.request(action, payload)
    local declared = type(action) == "string" and ACTIONS[action] or nil
    if not declared then
        return nil, "That is not something you can do."
    end
    if payload ~= nil and type(payload) ~= "table" then
        return nil, "That is not something you can do."
    end
    payload = payload or {}

    local args = {}
    for field, kind in pairs(declared.fields) do
        local given = payload[field]
        if kind == "integer" then
            -- A form field is a string even when it holds a number. Whether
            -- the number is allowed is still the server's business: it
            -- declares the range and refuses anything outside it.
            local number = math.tointeger(tonumber(given))
            if not number then
                return nil, "That needs to be a number."
            end
            args[field] = number
        elseif kind == "money" then
            local amount = cents(given)
            if not amount then
                return nil, "That needs to be an amount of money, like 200 or 12.50."
            end
            args[field] = amount
        else
            if type(given) ~= "string" then
                return nil, "Fill that in."
            end
            local value = trim(given)
            if value == "" then
                return nil, "Fill that in."
            end
            if #value > MAX_FIELD then
                return nil, "That is too long."
            end
            args[field] = value
        end
    end

    -- Undeclared fields are refused, not dropped. A page sending a field this
    -- action does not take is either a bug or somebody trying one on, and
    -- silently ignoring it means neither is ever noticed.
    for field in pairs(payload) do
        if declared.fields[field] == nil then
            return nil, "That is not something you can do."
        end
    end

    return declared.command, args
end

-- ------------------------------------------------------------- what is shown

--- The picker's view of a `character.list` answer.
---
--- Everything here is already decided by the server. The page is given names,
--- states and money as text, and the one number it could be tempted to reason
--- with — how many people are allowed — is given as a count to print, not as
--- permission to grant. The page always offers to make somebody new; whether
--- that is allowed is answered by the server refusing it.
function NuiState.picker(value)
    if type(value) ~= "table" then
        return { people = {}, used = 0, limit = 0, empty = true }
    end
    local people = {}
    for _, row in ipairs(value.characters or {}) do
        people[#people + 1] = {
            character = row.character,
            name = row.name,
            state = row.state,
            money = ClientState.money(row.wallet),
            playing = row.playing == true,
            -- A person who has retired is not in this list at all, so the only
            -- state worth drawing differently is the one being played.
            note = row.state == "dead" and "in hospital" or nil,
        }
    end
    return {
        people = people,
        used = #people,
        limit = value.limit or 0,
        empty = #people == 0,
    }
end

--- A time in the city, as somebody would say it.
---
--- The server hands out city milliseconds. Turning that into words is display,
--- the same as money is: the page is given the number and shows it, and
--- nothing is decided from it here.
function NuiState.when(ms)
    if math.type(ms) ~= "integer" or ms < 0 then return "" end
    local day = ms // 86400000
    local hour = (ms % 86400000) // 3600000
    local minute = (ms % 3600000) // 60000
    return ("day %d, %02d:%02d"):format(day, hour, minute)
end

--- Grams as somebody reads them. Under a kilo stays in grams, because a
--- bottle of water is 500g and "0.5kg" helps nobody.
function NuiState.weight(grams)
    if math.type(grams) ~= "integer" then return "?" end
    if grams < 1000 then return ("%dg"):format(grams) end
    return ("%.1fkg"):format(grams / 1000):gsub("%.0kg$", "kg")
end

--- What a person is carrying, ready to draw.
function NuiState.pockets(value)
    if type(value) ~= "table" then
        return { items = {}, empty = true, slots_used = 0, slots = 0,
                 weight = "0g", capacity = "0g", full = "" }
    end
    local items = {}
    for _, row in ipairs(value.items or {}) do
        items[#items + 1] = {
            item = row.item,
            label = row.label or row.item,
            count = row.count or 1,
            instance = row.instance,
            -- A stack of one does not need a number on it.
            stack = (row.count or 1) > 1 and tostring(row.count) or nil,
        }
    end
    local used, capacity = value.weight or 0, value.capacity or 0
    return {
        items = items,
        empty = #items == 0,
        slots_used = value.slots_used or 0,
        slots = value.slots or 0,
        weight = NuiState.weight(used),
        capacity = NuiState.weight(capacity),
        -- A proportion to draw a bar with, never a rule. Whether one more
        -- thing fits is answered by the server refusing to put it there.
        full = capacity > 0 and math.floor((used / capacity) * 100) or 0,
    }
end

--- Who has been in touch.
function NuiState.inbox(value)
    if type(value) ~= "table" then return { number = "", threads = {}, empty = true } end
    local threads = {}
    for _, row in ipairs(value.threads or {}) do
        threads[#threads + 1] = {
            number = row.number,
            last = row.last,
            outgoing = row.outgoing == true,
            when = NuiState.when(row.at),
        }
    end
    return { number = value.number or "", threads = threads, empty = #threads == 0 }
end

--- What was said between two numbers, oldest first.
---
--- The server answers newest first, which is the right order to page through
--- and the wrong order to read. A conversation reads down.
function NuiState.thread(value)
    if type(value) ~= "table" then return { with = "", messages = {}, empty = true } end
    local messages = {}
    for _, row in ipairs(value.messages or {}) do
        table.insert(messages, 1, {
            body = row.body,
            mine = row.from == value.number,
            when = NuiState.when(row.at),
            sequence = row.sequence,
        })
    end
    return { number = value.number or "", with = value.with or "",
             messages = messages, empty = #messages == 0 }
end

--- A shop counter.
---
--- Prices arrive as whole minor units and are shown as money. A row with no
--- buy price is something the shop will take and not sell; one with no sell
--- price is something it sells and will not take back. Both happen, and a
--- dash is the honest way to draw them.
function NuiState.shop(value)
    if type(value) ~= "table" then
        return { name = "", state = "", lines = {}, empty = true }
    end
    local lines = {}
    for _, row in ipairs(value.lines or {}) do
        lines[#lines + 1] = {
            item = row.item,
            label = row.label or row.item,
            buy = row.buy and NuiState.money(row.buy) or nil,
            sell = row.sell and NuiState.money(row.sell) or nil,
            stock = row.stock or 0,
            -- Out of stock is worth drawing differently. It is still not a
            -- rule: buying the last one is refused by the shop, not here.
            bare = (row.stock or 0) <= 0,
        }
    end
    return {
        name = value.name or "",
        state = value.state or "",
        shut = value.state ~= nil and value.state ~= "open",
        lines = lines,
        empty = #lines == 0,
    }
end

--- What a row may offer a player, as declared action names.
---
--- The page draws these and nothing else. Until it did, it drew a **Go in** on
--- every place it was given, so a seeded city offered that button on four rows
--- out of seven where `property.enter` refuses it every time, for everybody,
--- forever: two bank branches and two shop premises, all held by the council
--- and none of them somewhere a person lives.
---
--- "Drawn, never obeyed" is still the rule and this does not weaken it. A flat
--- somebody else owns still offers its door and is still refused by the server
--- -- that refusal is a fact about *this person today*. A branch is not a door
--- anybody is ever let through, and offering one is not deference to the
--- server, it is a control that cannot work.
---
--- Every name here is a key of `ACTIONS`, which `spec/nui_spec.lua` holds: a
--- button the page draws that the page cannot ask for is the same defect from
--- the other end.
local function offers(row)
    local out = {}
    if row.for_sale == true and row.price ~= nil then out[#out + 1] = "purchase" end
    -- `enterable` absent means an older server that did not say. Offering the
    -- door then is the behaviour that shipped, which is the safe way to be
    -- wrong: a refusal, not a missing way in.
    if row.enterable ~= false then out[#out + 1] = "enter" end
    return out
end

-- ------------------------------------------------------- words, not keys
--
-- The screens printed the server's keys as they came: a bank line said
-- "deposit", a door "apartment · for sale", a branch "bank", and the job board
-- "on a shift: delivery". A key turned into words is display, the same as
-- money, so it is turned here where a spec reads it and the page prints it.

--- A key as words: underscores as spaces, the first letter a capital.
local function words(key)
    if type(key) ~= "string" or key == "" then return nil end
    local text = key:gsub("_", " ")
    return (text:gsub("^%l", string.upper))
end

local KIND_WORDS = {
    apartment = "Apartment", house = "House", garage = "Garage", lockup = "Lock-up",
    office = "Office", bank = "Bank branch", shop = "Shop premises",
}

local function kind_words(kind)
    return KIND_WORDS[kind] or words(kind) or "A place"
end

--- A bank line's reason as words. A transfer is the same reason both ways, so
--- which way it went is part of the words.
local REASON_WORDS = {
    deposit = "Paid in", withdrawal = "Taken out", ["account opening"] = "Account opening fee",
}

local function reason_words(reason, incoming)
    if reason == "transfer" then return incoming and "Transfer in" or "Transfer out" end
    return REASON_WORDS[reason] or words(reason) or "Moved"
end

--- What is close enough to walk up to.
function NuiState.nearby(value)
    if type(value) ~= "table" then
        return { shops = {}, places = {}, empty = true }
    end
    local shops, places = {}, {}
    for _, row in ipairs(value.shops or {}) do
        local shut = row.state ~= nil and row.state ~= "open"
        local where = "Shop"
        if shut then where = "Shut" end
        shops[#shops + 1] = { shop = row.shop, name = row.name,
                              shut = shut,
                              where = where,
                              -- A counter is always offered: whether it is shut
                              -- is the shop's answer, and it can open again.
                              offers = { "shop" } }
    end
    for _, row in ipairs(value.places or {}) do
        local for_sale = row.for_sale == true
        places[#places + 1] = {
            place = row.place,
            address = row.address or row.place,
            kind = row.kind,
            mine = row.mine == true,
            -- Drawn, never obeyed. The page always offers the door; whether it
            -- opens is property.enter refusing.
            may_enter = row.may_enter == true,
            -- Same discipline, and the reason a door can be bought at all from
            -- a screen: what it costs is drawn, and whether this person can
            -- have it is property.buy refusing. A page edited to show a
            -- cheaper number still sends nothing but the address.
            for_sale = for_sale,
            price = for_sale and NuiState.money(row.price) or nil,
            enterable = row.enterable ~= false,
        }
        local where = kind_words(row.kind)
        if row.mine == true then
            where = "Yours"
        elseif for_sale then
            where = where .. " · for sale"
        end
        places[#places].where = where
        places[#places].offers = offers({
            for_sale = for_sale, price = places[#places].price,
            enterable = row.enterable,
        })
    end
    return { shops = shops, places = places,
             empty = #shops == 0 and #places == 0 }
end

--- A bank counter.
---
--- Money is shown as money and never as a number the page did arithmetic on:
--- what is in the account is what the ledger says, read back after every move.
--- A person with no account gets an empty one rather than a missing screen,
--- because "you have no account here" is a thing to draw and a reason to offer
--- opening one.
function NuiState.bank(value)
    if type(value) ~= "table" then
        return { open = false, number = "", balance = "", lines = {}, empty = true }
    end
    local lines = {}
    for _, row in ipairs(value.lines or {}) do
        local amount = row.amount or 0
        lines[#lines + 1] = {
            sequence = row.sequence,
            amount = NuiState.money(amount),
            -- Which way the money went, drawn rather than worked out from a
            -- sign the page would have to interpret.
            incoming = amount >= 0,
            reason = row.reason or "",
            label = reason_words(row.reason, amount >= 0),
            reference = row.reference,
        }
    end
    return {
        open = value.account ~= nil,
        number = value.number or "",
        balance = value.balance and NuiState.money(value.balance) or "",
        state = value.state or "",
        frozen = value.state ~= nil and value.state ~= "open",
        lines = lines,
        empty = #lines == 0,
    }
end

--- A job board.
---
--- Every number here is a count to draw. Whether this person may take a shift
--- on is `work.start` refusing, and the page offers the row either way -- the
--- same rule the door and the counter keep.
function NuiState.jobs(value)
    if type(value) ~= "table" then
        return { employers = {}, working = nil, empty = true }
    end
    local employers = {}
    local working_label = nil
    for _, row in ipairs(value.employers or {}) do
        local offers = {}
        local name = row.name or row.employer
        for _, job in ipairs(row.jobs or {}) do
            local waiting = job.ready_in or 0
            local where = ("%s · %d min"):format(tostring(name), job.minutes or 0)
            if waiting > 0 then where = where .. (" · ready in %d min"):format(waiting) end
            offers[#offers + 1] = {
                job = job.job,
                label = job.label or job.job,
                pay = NuiState.money(job.pay or 0),
                minutes = job.minutes or 0,
                -- A wait to print, never a rule: `work.start` refuses.
                ready_in = waiting,
                waiting = waiting > 0 and ("%d min"):format(waiting) or nil,
                where = where,
            }
            if value.working ~= nil and job.job == value.working and working_label == nil then
                working_label = job.label
            end
        end
        employers[#employers + 1] = {
            employer = row.employer,
            name = name,
            hiring = row.hiring == true,
            jobs = offers,
        }
    end
    if value.working ~= nil and working_label == nil then working_label = words(value.working) end
    return {
        employers = employers,
        -- What they are on now, so the page can offer clocking off instead.
        working = value.working,
        working_label = working_label,
        empty = #employers == 0,
    }
end

--- A stash, beside the pockets it trades with.
---
--- Two containers, drawn the same way, so moving a thing is the same gesture
--- in both directions. Which container a thing is in is the only difference.
function NuiState.stash(pockets_value, stash_value, opts)
    opts = opts or {}
    return {
        here = NuiState.pockets(pockets_value),
        there = NuiState.pockets(stash_value),
        pockets_id = opts.pockets,
        stash_id = opts.stash,
        address = opts.address or "",
    }
end

--- What goes back to the page after it asked for something.
---
--- `ok` and a line, and on a read the view to draw. No refusal code: the page
--- cannot act on what it is not told.
--- What has to happen after an action succeeds, before the page is answered.
---
--- Only one action has one, and it is the one that bit: making somebody and
--- then not being them is a dead end. A player created a character, the screen
--- closed, no character was selected, and the server answered `not_playing`
--- forever while the page showed a generic error.
---
--- It cannot be the page's job. `reply` hands back ok, a line and a view, and
--- deliberately not the id of what was just made -- so the page has nothing to
--- select with. The adapter holds the outcome, so the adapter chains it, and
--- the decision about what chains to what lives here where it can be tested
--- without a game.
---
--- And becoming them is not always one request. `character.select` refuses an
--- account that is already playing somebody else -- `character.release` is, in
--- the server's words, "stop playing, on disconnect or when switching" -- so a
--- player who was somebody and pressed Begin had a person made, not played, and
--- the page told it had worked. `playing` is who the last `character.list` said
--- this account is playing, which is what the picker was drawn from.
---
--- Returns the requests to make, in order, as { command, args } -- empty when
--- nothing follows.
function NuiState.follow_up(action, outcome, playing)
    if action ~= "create" then return {} end
    if type(outcome) ~= "table" or outcome.ok ~= true then return {} end
    local made = outcome.value
    if type(made) ~= "string" or made == "" then return {} end
    return NuiState.steps("select", "character.select", { character = made }, playing)
end

--- The requests a page action is sent as, in order. Almost always the one it
--- names. Asking to play somebody while playing somebody else is two: let go,
--- then select. Play on anybody else was refused every time once a person had
--- been played, because the page only ever sent the second.
---
--- Each is asked in turn and the last one's answer is the answer: a refused
--- letting-go is not a reason to stop, since the select is what says whether
--- this person can be played. Nothing here reads a refusal to decide what to
--- ask next. Picking the person you already are lets go of nobody, because
--- letting go ends whatever they were in the middle of.
function NuiState.steps(action, command, args, playing)
    local steps = {}
    if action == "select" and type(args) == "table"
        and playing ~= nil and playing ~= args.character then
        steps[#steps + 1] = { command = "character.release", args = {} }
    end
    steps[#steps + 1] = { command = command, args = args }
    return steps
end

--- What the page is told after somebody was made: `made` is the create's
--- answer, `chosen` the answer to playing them, `view` the picker drawn again.
---
--- The create is done either way, so the person is drawn. Whether they are the
--- one being played is `chosen`, and a page told "done" when they are not closes
--- on a player who is still whoever they were. The line is this file's own,
--- because the refusal behind it can be a server's internal words.
local MADE_NOT_PLAYED = "They were made, but you are not playing them yet. Press Play beside their name."

function NuiState.made(made, chosen, view)
    if type(chosen) == "table" and chosen.ok == true then
        return NuiState.reply(chosen, view)
    end
    return { ok = false, message = MADE_NOT_PLAYED, view = view }
end

function NuiState.reply(outcome, view)
    local ok = type(outcome) == "table" and outcome.ok == true
    return {
        ok = ok,
        message = ClientState.say(outcome),
        view = ok and view or nil,
    }
end

--- What goes back to the page when an action worked and its screen was read
--- again, to draw what the server now says.
---
--- The read can fail on its own -- asked too often, or not answered in time --
--- and the phone and the stash drew that nothing as an answer: a message sent
--- and then an inbox with nobody in it, a stash just filled drawn as "Nothing put
--- down yet.", and the page told all was well. Nothing had been lost; the screen
--- said it had. A read that failed sends no view, so the page keeps what it was
--- showing, and a line saying it may be out of date.
---
--- `...` is every read the view needs, and `build` makes the view from their
--- values in order. It is only called when all of them came back. Counted with
--- select, not ipairs, so a read that never arrived is a failed read and not the
--- end of the list.
--- What the page is told when something worked: a short line, or nothing.
---
--- A refusal was drawn in words and a success in silence. Buy, Pay in and Take
--- it answered with a redrawn screen and nothing said, so the only sign a press
--- had done anything was a number changing somewhere. Reads say nothing -- the
--- screen they draw is the answer -- and so does Play, which closes the page.
local DONE = {
    buy = "Bought.", sell = "Sold.", drop = "Dropped.", use = "Used.", send = "Sent.",
    stow = "Moved.", purchase = "Bought. It is yours now.", account = "Account opened.",
    clockon = "You are on the clock.", clockoff = "Clocked off.", walkoff = "You walked off the job.",
    retire = "Retired.",
    deposit = function(args) return ("Paid in %s."):format(NuiState.money(args.amount)) end,
    withdraw = function(args) return ("Took out %s."):format(NuiState.money(args.amount)) end,
}

--- `reply` with the line added, when it worked and nothing else was said. A
--- refusal keeps its own words, and so does a screen that could not be read
--- again: that line is the more important one.
function NuiState.told(action, args, reply)
    if type(reply) ~= "table" or reply.ok ~= true or reply.message ~= nil then return reply end
    local line = DONE[action]
    if type(line) == "function" then line = line(type(args) == "table" and args or {}) end
    reply.message = line
    return reply
end

local STALE = "That went through, but the screen could not be read again, so it may be out of date."

function NuiState.read_back(outcome, build, ...)
    if type(outcome) ~= "table" or outcome.ok ~= true then return NuiState.reply(outcome) end
    local count = select("#", ...)
    local values = {}
    for i = 1, count do
        local read = select(i, ...)
        if type(read) ~= "table" or read.ok ~= true then
            return { ok = true, message = STALE, view = nil }
        end
        values[i] = read.value
    end
    return NuiState.reply(outcome, build(table.unpack(values, 1, count)))
end

NyrNuiState = NuiState

return NuiState
