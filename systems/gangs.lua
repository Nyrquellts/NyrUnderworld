--- Crews, and the ground they hold.
--
-- Standing has done most of this since the memory system: a score per party,
-- floors for allegiance that is earned rather than lent, and decay that does
-- not touch a floor. A gang is already a party you can stand well or badly
-- with. What was missing is the membership and the map.
--
-- Three things here are deliberately not new machinery:
--
--   A treasury is a ledger account, so a crew cannot spend what it does not
--   have and the books still sum to nothing after every payout.
--
--   Who holds a block is the ownership register, so two crews taking one
--   block in the same tick cannot both win, for the same reason two people
--   cannot buy one flat.
--
--   Being in a crew is a floor under your standing with it, so a member does
--   not drift back to stranger while they are still a member, and does start
--   drifting the moment they are not.
--
-- The rule, again: rank is given by somebody who already holds it. There is no
-- command that raises your own rank, and the one that raises somebody else's
-- refuses to raise them to or above the giver -- except a boss handing the crew
-- over, which swaps the two of them, so a crew always has exactly one boss.

local Entity = require("domain.entity")
local Money = require("domain.money")
local Clock = require("core.clock")
local Characters = require("systems.characters")

local Gangs = {}

local MEMBER, OFFICER, BOSS = 1, 2, 3
local RANK_NAMES = { [MEMBER] = "member", [OFFICER] = "officer", [BOSS] = "boss" }
local DEFAULT_INVITE_MS = 5 * Clock.MS_PER_MINUTE
local DEFAULT_CLAIM_MS = 2 * Clock.MS_PER_MINUTE
local DEFAULT_TRIBUTE = 10          -- a whole percentage of a till, daily
local NEUTRAL = "state:council"
local PARTY = "gang:"

Gangs.MEMBER, Gangs.OFFICER, Gangs.BOSS = MEMBER, OFFICER, BOSS
Gangs.RANK_NAMES = RANK_NAMES

Gangs.Crew = Entity.define("gng", {
    fields = {
        name = { type = "string", required = true, min = 2, max = 32 },
        tag = { type = "string", required = true, min = 2, max = 4 },
        founder = { type = "id", kind = "chr", required = true },
        -- character id -> rank. The roster is on the crew rather than on each
        -- person because "who is in this" is the question that gets asked, and
        -- the other direction is an index built from it.
        roster = { type = "table", required = true },
    },
    states = { active = { "disbanded" }, disbanded = {} },
    initial = "active",
})

Gangs.Turf = Entity.define("trf", {
    fields = {
        name = { type = "string", required = true, min = 2, max = 32 },
        -- The addresses on this ground. Declared by the server when the turf
        -- is drawn, because what is where is the city's business.
        places = { type = "table", default = {} },
        x = { type = "number", default = 0.0 },
        y = { type = "number", default = 0.0 },
        z = { type = "number", default = 0.0 },
        radius = { type = "number", default = 60.0, min = 1.0, max = 1000.0 },
    },
    states = { held = { "held" } },
    initial = "held",
})

local Crew, Turf = Gangs.Crew, Gangs.Turf

--- The ledger account a crew keeps its money in, and the standing party it is.
--- The same name in both, because it is the same crew.
function Gangs.party(crew_id) return PARTY .. crew_id end

--- opts.invite_ms       how long an invitation stands, in real milliseconds
--- opts.claim_ms        how long taking a block takes, in real milliseconds
--- opts.tribute_percent a whole percentage of a till, daily, to whoever holds it
function Gangs.system(opts)
    opts = opts or {}
    local invite_ms = opts.invite_ms or DEFAULT_INVITE_MS
    local claim_ms = opts.claim_ms or DEFAULT_CLAIM_MS
    local tribute = opts.tribute_percent or DEFAULT_TRIBUTE
    assert(math.type(tribute) == "integer" and tribute >= 0 and tribute < 100,
        "a tribute is a whole percentage below one hundred")

    return {
        name = "gangs",
        requires = { "characters", "memory" },
        install = function(world)
            local crews = world:repository(Crew)
            local turfs = world:repository(Turf)
            local invites = {}         -- crew id -> character -> when it lapses
            local claims = {}          -- character -> { turf, at }

            -- Real time as city time at the pace the city is running now,
            -- rounded up: the same reckoning reach uses in systems/inventory.
            -- An invitation and holding a block are both waited for by a
            -- person, in real time. They were city time, and at the pace
            -- config.lua ships -- sixty city milliseconds to a real one -- an
            -- invitation went cold in five real seconds and a block was taken
            -- in two. The clock is asked every time, because loading a saved
            -- city replaces it.
            local function city_span(real_ms)
                return math.ceil(real_ms * world.clock:rate())
            end

            local function crew_of(character)
                for _, crew in ipairs(crews:where(function(candidate)
                    return candidate.state == "active" and candidate:get("roster")[character] ~= nil
                end)) do
                    return crew
                end
                return nil
            end

            local function rank_of(crew, character)
                return crew:get("roster")[character]
            end

            local function set_rank(crew, character, rank)
                local roster = {}
                for who, held in pairs(crew:get("roster")) do roster[who] = held end
                roster[character] = rank
                crew:set("roster", roster)
                crews:save(crew)
            end

            local function holder_of(turf_id)
                return world.ownership:owner_of(turf_id) or NEUTRAL
            end

            --- The crew holding a block, if there is one and it still exists.
            local function active_holder(turf_id)
                local party = world.ownership:owner_of(turf_id)
                if not party or party:sub(1, #PARTY) ~= PARTY then return nil end
                local crew = crews:load(party:sub(#PARTY + 1))
                if not crew or crew.state ~= "active" then return nil end
                return crew
            end

            local function member_context(ctx, needed)
                if not ctx.actor then
                    return nil, nil, ctx.refuse("not_playing", "You are not playing anybody.")
                end
                local crew = crew_of(ctx.actor)
                if not crew then return nil, nil, ctx.refuse("no_crew", "You are not in a crew.") end
                local rank = rank_of(crew, ctx.actor)
                if needed and rank < needed then
                    return nil, nil, ctx.refuse("outranked",
                        ("You have to be %s for that."):format(RANK_NAMES[needed]))
                end
                return crew, rank, nil
            end

            world.services.gangs = {
                crews = crews,
                turfs = turfs,
                party = Gangs.party,
                crew_of = crew_of,
                rank_of = rank_of,
                holder_of = holder_of,
                treasury_of = function(crew) return world.ledger:balance(Gangs.party(crew.id)) end,
                --- Found a crew. Not a command: which crews exist is the
                --- city's business, and a client asking for one would be a
                --- client minting factions.
                found = function(name, tag, founder)
                    local crew, why = crews:create({
                        name = name, tag = tag:upper(), founder = founder,
                        roster = { [founder] = BOSS },
                    })
                    if not crew then error(("cannot found %s: %s"):format(name, tostring(why)), 2) end
                    -- Being in a crew is a floor under your standing with it.
                    world.services.standing:set_floor(founder, Gangs.party(crew.id), 50)
                    world.events:emit("gang.founded", { crew = crew.id, name = name, founder = founder })
                    return crew
                end,
                --- Draw a block on the map.
                draw = function(name, turf_opts)
                    turf_opts = turf_opts or {}
                    local places = {}
                    for index, place in ipairs(turf_opts.places or {}) do places[index] = place end
                    local turf, why = turfs:create({
                        name = name, places = places,
                        x = turf_opts.x, y = turf_opts.y, z = turf_opts.z,
                        radius = turf_opts.radius,
                    })
                    if not turf then error(("cannot draw %s: %s"):format(name, tostring(why)), 2) end
                    return turf
                end,
                invite_standing = function(crew_id, character)
                    local per_crew = invites[crew_id]
                    return per_crew and per_crew[character] or nil
                end,
            }

            world:persist_with("gangs", {
                save = function()
                    -- Invitations are a conversation happening now, not a state
                    -- of the world. They do not survive a restart on purpose:
                    -- an invitation from last Tuesday is not an invitation.
                    return { claims = {} }
                end,
                load = function()
                    invites, claims = {}, {}
                    return true
                end,
            })

            world:define("gang.roster", {
                read_only = true,
                summary = "who is in your crew",
                rate = { per_minute = 20 },
                args = {},
                handler = function(ctx)
                    local crew, rank, refused = member_context(ctx)
                    if refused then return refused end
                    local members = {}
                    for who, held in pairs(crew:get("roster")) do
                        members[#members + 1] = { character = who, rank = held,
                                                  title = RANK_NAMES[held] }
                    end
                    table.sort(members, function(a, b)
                        if a.rank ~= b.rank then return a.rank > b.rank end
                        return a.character < b.character
                    end)
                    return ctx.ok({
                        crew = crew.id, name = crew:get("name"), tag = crew:get("tag"),
                        your_rank = rank, members = members,
                        treasury = world.ledger:balance(Gangs.party(crew.id)):to_minor(),
                    })
                end,
            })

            world:define("gang.invite", {
                summary = "ask somebody to join",
                rate = { per_minute = 10 },
                args = { target = { type = "id", kind = "chr", required = true } },
                handler = function(ctx, args)
                    local crew, _, refused = member_context(ctx, OFFICER)
                    if refused then return refused end
                    if args.target == ctx.actor then
                        return ctx.refuse("not_yourself", "You are already in it.")
                    end
                    if crew_of(args.target) then
                        return ctx.refuse("already_in_a_crew", "They are in a crew already.")
                    end
                    local per_crew = invites[crew.id]
                    if not per_crew then
                        per_crew = {}
                        invites[crew.id] = per_crew
                    end
                    per_crew[args.target] = ctx.now + city_span(invite_ms)
                    ctx.emit("gang.invited", { crew = crew.id, target = args.target, by = ctx.actor })
                    return ctx.ok({ lapses_at = per_crew[args.target] })
                end,
            })

            world:define("gang.join", {
                summary = "take up an invitation",
                rate = { per_minute = 10 },
                args = { crew = { type = "id", kind = "gng", required = true } },
                handler = function(ctx, args)
                    if not ctx.actor then return ctx.refuse("not_playing", "You are not playing anybody.") end
                    if crew_of(ctx.actor) then
                        return ctx.refuse("already_in_a_crew", "Leave the one you are in first.")
                    end
                    local crew = crews:load(args.crew)
                    if not crew or crew.state ~= "active" then
                        return ctx.refuse("no_such_crew", "There is no such crew.")
                    end
                    -- An invitation, not a request. Joining is something you
                    -- are asked to do; without that this is a command that
                    -- puts anybody in anything.
                    local per_crew = invites[crew.id] or {}
                    local standing = per_crew[ctx.actor]
                    if not standing then
                        return ctx.refuse("not_invited", "Nobody asked you.")
                    end
                    if standing <= ctx.now then
                        per_crew[ctx.actor] = nil
                        return ctx.refuse("invitation_lapsed", "That offer has gone cold.")
                    end
                    per_crew[ctx.actor] = nil

                    set_rank(crew, ctx.actor, MEMBER)
                    world.services.standing:set_floor(ctx.actor, Gangs.party(crew.id), 50)
                    -- Under this command's operation id. Named by crew and person
                    -- alone, coming back to a crew was the same join forever.
                    world.services.remember(("joined:%s"):format(ctx.operation_id), {
                        subject = ctx.actor, kind = "gang.joined", weight = 5,
                        meta = { crew = crew.id, name = crew:get("name") },
                    })
                    ctx.emit("gang.joined", { crew = crew.id, character = ctx.actor })
                    return ctx.ok({ crew = crew.id, name = crew:get("name") })
                end,
            })

            local function remove(crew, character, reason, operation_id)
                set_rank(crew, character, nil)
                -- Walking out of a crew is walking off whatever ground they were
                -- taking for it.
                claims[character] = nil
                -- The floor goes with the membership. Standing earned inside a
                -- crew starts decaying the moment you are outside it, which is
                -- the point of a floor being a membership and not a gift.
                world.services.standing:set_floor(character, Gangs.party(crew.id), 0)
                world.services.remember(("left:%s"):format(operation_id), {
                    subject = character, kind = "gang.left", weight = 5,
                    meta = { crew = crew.id, name = crew:get("name"), reason = reason },
                })
            end

            world:define("gang.leave", {
                summary = "walk away from your crew",
                args = {},
                handler = function(ctx)
                    local crew, rank, refused = member_context(ctx)
                    if refused then return refused end
                    if rank == BOSS then
                        local others = 0
                        for who in pairs(crew:get("roster")) do
                            if who ~= ctx.actor then others = others + 1 end
                        end
                        if others > 0 then
                            return ctx.refuse("hand_it_over",
                                "Make somebody else boss before you go.")
                        end
                        crew:transition("disbanded", { reason = "the last of them left" })
                        crews:save(crew)

                        -- A crew that is gone keeps nothing. Kept, its pot was out
                        -- of reach of every command for good, and its ground went
                        -- on paying that pot a cut of every till on it, every day.
                        -- The pot goes to the last boss, who could have taken it
                        -- out a moment before; sending it out of the city would
                        -- take a player's money for forgetting to. The ground goes
                        -- back to nobody, for anybody to take.
                        local party = Gangs.party(crew.id)
                        local pot = world.ledger:balance(party)
                        if pot:is_positive() then
                            world.ledger:transfer(("disband:%s"):format(ctx.operation_id), party,
                                Characters.wallet(ctx.actor), pot, { reason = "crew disbanded" })
                            world.services.remember(("gangout:%s"):format(ctx.operation_id), {
                                subject = ctx.actor, kind = "gang.withdrew", weight = 1,
                                meta = { crew = crew.id, amount = pot:to_minor(), disbanded = true },
                            })
                        end
                        for _, held in ipairs(world.ownership:assets_of(party)) do
                            world.ownership:release(("disband:%s:%s"):format(held, ctx.operation_id),
                                held, party, { reason = "crew disbanded" })
                        end
                    end
                    remove(crew, ctx.actor, "left", ctx.operation_id)
                    ctx.emit("gang.left", { crew = crew.id, character = ctx.actor })
                    return ctx.ok()
                end,
            })

            world:define("gang.kick", {
                summary = "throw somebody out",
                args = { target = { type = "id", kind = "chr", required = true } },
                handler = function(ctx, args)
                    local crew, rank, refused = member_context(ctx, OFFICER)
                    if refused then return refused end
                    local held = rank_of(crew, args.target)
                    if not held then return ctx.refuse("not_in_your_crew", "They are not in it.") end
                    if args.target == ctx.actor then
                        return ctx.refuse("not_yourself", "Leave instead.")
                    end
                    if held >= rank then
                        return ctx.refuse("outranked", "They are not yours to throw out.")
                    end
                    remove(crew, args.target, "thrown out", ctx.operation_id)
                    ctx.emit("gang.kicked", { crew = crew.id, character = args.target, by = ctx.actor })
                    return ctx.ok()
                end,
            })

            world:define("gang.promote", {
                summary = "give somebody rank",
                args = {
                    target = { type = "id", kind = "chr", required = true },
                    rank = { type = "integer", required = true, min = MEMBER, max = BOSS },
                },
                handler = function(ctx, args)
                    local crew, rank, refused = member_context(ctx, OFFICER)
                    if refused then return refused end
                    local held = rank_of(crew, args.target)
                    if not held then return ctx.refuse("not_in_your_crew", "They are not in it.") end
                    if args.target == ctx.actor then
                        return ctx.refuse("not_yourself", "You cannot give yourself rank.")
                    end
                    -- A boss hands the crew over, and only as a swap in one save:
                    -- the new boss steps up and the old one steps down to officer,
                    -- so a crew never has two bosses or none. Without it nothing
                    -- could make anybody boss, since rank is never given at or
                    -- above the giver and nobody is above a boss: a boss told to
                    -- hand it over before leaving could not, and a boss who
                    -- stopped playing left a crew nobody could run.
                    if rank == BOSS and args.rank == BOSS then
                        local roster = {}
                        for who, held_rank in pairs(crew:get("roster")) do roster[who] = held_rank end
                        roster[args.target] = BOSS
                        roster[ctx.actor] = OFFICER
                        crew:set("roster", roster)
                        crews:save(crew)
                        ctx.emit("gang.ranked", { crew = crew.id, character = args.target,
                            rank = BOSS, by = ctx.actor })
                        ctx.emit("gang.ranked", { crew = crew.id, character = ctx.actor,
                            rank = OFFICER, by = ctx.actor })
                        return ctx.ok({ rank = BOSS, title = RANK_NAMES[BOSS] })
                    end
                    -- Rank is given by somebody who already holds it, and never
                    -- to or above the giver. Without the second half, one
                    -- officer promoting another to boss hands the crew away.
                    if args.rank >= rank then
                        return ctx.refuse("outranked", "That is not yours to give.")
                    end
                    if held >= rank then
                        return ctx.refuse("outranked", "They are not yours to rank.")
                    end
                    set_rank(crew, args.target, args.rank)
                    ctx.emit("gang.ranked", { crew = crew.id, character = args.target,
                        rank = args.rank, by = ctx.actor })
                    return ctx.ok({ rank = args.rank, title = RANK_NAMES[args.rank] })
                end,
            })

            -- ------------------------------------------------------ treasury

            world:define("gang.deposit", {
                summary = "put money into the crew treasury",
                rate = { per_minute = 20 },
                args = { amount = { type = "integer", required = true, min = 1, max = 100000000 } },
                handler = function(ctx, args)
                    local crew, _, refused = member_context(ctx)
                    if refused then return refused end
                    local ok, why = world.ledger:transfer(
                        ctx.operation_id or ("gangin:%s:%d"):format(ctx.actor, ctx.now),
                        Characters.wallet(ctx.actor), Gangs.party(crew.id),
                        Money.from_minor(args.amount), { reason = "crew treasury" })
                    if not ok then
                        return ctx.refuse("not_carrying", "You are not carrying that much.",
                            { detail = why })
                    end
                    ctx.emit("gang.deposited", { crew = crew.id, by = ctx.actor, amount = args.amount })
                    return ctx.ok({ treasury = world.ledger:balance(Gangs.party(crew.id)):to_minor() })
                end,
            })

            world:define("gang.withdraw", {
                summary = "take money out of the crew treasury",
                rate = { per_minute = 20 },
                args = { amount = { type = "integer", required = true, min = 1, max = 100000000 } },
                handler = function(ctx, args)
                    local crew, _, refused = member_context(ctx, OFFICER)
                    if refused then return refused end
                    local ok, why = world.ledger:transfer(
                        ctx.operation_id or ("gangout:%s:%d"):format(ctx.actor, ctx.now),
                        Gangs.party(crew.id), Characters.wallet(ctx.actor),
                        Money.from_minor(args.amount), { reason = "crew treasury" })
                    if not ok then
                        return ctx.refuse("treasury_short", "There is not that much in it.",
                            { detail = why })
                    end
                    -- Who took what out of the pot is the question that ends
                    -- crews, so it is a thing the city keeps rather than a
                    -- thing anybody has to remember. Under this command's
                    -- operation id: named by the city millisecond, the second
                    -- of two withdrawals in one server tick left no line.
                    world.services.remember(("gangout:%s"):format(ctx.operation_id), {
                        subject = ctx.actor, kind = "gang.withdrew", weight = 1,
                        meta = { crew = crew.id, amount = args.amount },
                    })
                    ctx.emit("gang.withdrew", { crew = crew.id, by = ctx.actor, amount = args.amount })
                    return ctx.ok({ treasury = world.ledger:balance(Gangs.party(crew.id)):to_minor() })
                end,
            })

            -- --------------------------------------------------------- turf

            world:define("gang.claim", {
                summary = "take a block for your crew",
                rate = { per_minute = 6 },
                args = { turf = { type = "id", kind = "trf", required = true } },
                handler = function(ctx, args)
                    local crew, _, refused = member_context(ctx)
                    if refused then return refused end
                    local turf = turfs:load(args.turf)
                    if not turf then return ctx.refuse("no_such_turf", "There is no such block.") end

                    local held_by = holder_of(turf.id)
                    if held_by == Gangs.party(crew.id) then
                        return ctx.refuse("already_yours", "You already hold it.")
                    end

                    local check = world.services.proximity
                    if type(check) ~= "function" then
                        return ctx.refuse("no_proximity", "The server cannot tell where you are.")
                    end
                    if check(ctx.actor, turf.id) ~= true then
                        return ctx.refuse("too_far", "You are not on it.")
                    end

                    -- Taking ground happens over time, not on a button, and it is
                    -- done for a crew. The attempt was kept by person alone, kept
                    -- through leaving, and kept for good: somebody could begin on
                    -- a block for one crew, walk out, join its rival and take it
                    -- for them on the first press, or come back hours later and
                    -- finish at once. It now names its crew, leaving ends it, and
                    -- one ready for as long again as it took and not finished has
                    -- been walked away from.
                    local needed = city_span(claim_ms)
                    local attempt = claims[ctx.actor]
                    if attempt and ctx.now - attempt.at >= city_span(2 * claim_ms) then
                        attempt = nil
                    end
                    if not attempt or attempt.turf ~= turf.id or attempt.crew ~= crew.id then
                        claims[ctx.actor] = { turf = turf.id, crew = crew.id, at = ctx.now }
                        return ctx.refuse("working", "Hold it.",
                            { seconds = claim_ms // Clock.MS_PER_SECOND })
                    end
                    local waited = ctx.now - attempt.at
                    if waited < needed then
                        local left = math.ceil((needed - waited) / world.clock:rate())
                        return ctx.refuse("working", "Not yet.",
                            { seconds = left // Clock.MS_PER_SECOND + 1 })
                    end
                    claims[ctx.actor] = nil

                    -- Compare-and-swap on who holds it, the same as a flat and
                    -- the same as a car. Two crews in the same tick cannot both
                    -- win, because the second names a holder who no longer holds.
                    -- The operation id is this command's own. Built from the
                    -- crew and the city millisecond, a block taken, taken off
                    -- them and taken back in one server tick built the first id
                    -- again, and the ownership register throws rather than
                    -- refusing, because one id cannot mean two different moves.
                    -- The loser should be told somebody was faster, not handed a
                    -- server error.
                    local operation = ("turf:%s:%s"):format(turf.id, ctx.operation_id)
                    local taken, why
                    if world.ownership:owner_of(turf.id) == nil then
                        taken, why = world.ownership:claim(operation, turf.id,
                            Gangs.party(crew.id), { turf = turf:get("name") })
                    else
                        taken, why = world.ownership:transfer(operation, turf.id,
                            held_by, Gangs.party(crew.id), { turf = turf:get("name") })
                    end
                    if not taken then
                        return ctx.refuse("taken_already", "Somebody else got it first.",
                            { detail = why })
                    end

                    world.services.remember(operation, {
                        subject = ctx.actor, kind = "gang.claimed", weight = 10,
                        meta = { crew = crew.id, turf = turf.id, name = turf:get("name"),
                                 from = held_by },
                    })
                    ctx.emit("gang.claimed", { crew = crew.id, turf = turf.id,
                        by = ctx.actor, from = held_by })
                    return ctx.ok({ turf = turf.id, name = turf:get("name") })
                end,
            })

            -- A cut of what is made on ground you hold, once a city day. Only
            -- from shops, only from what is actually in the till, and only to a
            -- crew that still exists.
            if tribute > 0 then
                world:daily(4, 0, function()
                    if not world:has("shops") then return end
                    for _, turf in ipairs(turfs:where(function() return true end)) do
                        -- Nothing checked that last part, so a disbanded crew's
                        -- ground paid its pot every day, where nobody could ever
                        -- take it out. A disbanded crew lets go of its ground now,
                        -- and a city saved before that still has them holding it.
                        local crew = active_holder(turf.id)
                        if crew then
                            local party = Gangs.party(crew.id)
                            for _, place_id in ipairs(turf:get("places")) do
                                for _, shop in ipairs(world.services.shops.shops:where(function(candidate)
                                    return candidate:get("place") == place_id
                                end)) do
                                    local till = world.services.shops.till_of(shop)
                                    local cut = till:percent(tribute)
                                    if cut:is_positive() then
                                        world.ledger:transfer(
                                            ("tribute:%s:%d"):format(shop.id, world.clock:now()),
                                            world.services.shops.counter(shop.id), party, cut,
                                            { reason = "tribute", turf = turf:get("name") })
                                    end
                                end
                            end
                        end
                    end
                end, "gangs:tribute")
            end

            world:on("world.loaded", function()
                invites, claims = {}, {}
                crews:all()
                turfs:all()
            end, { label = "gangs:load" })

            world:on("character.released", function(payload)
                claims[payload.character] = nil
            end, { label = "gangs:release" })
        end,
    }
end

return Gangs
