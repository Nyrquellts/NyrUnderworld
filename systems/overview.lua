--- One read that answers "how am I doing".
--
-- Every number a player needs to see already exists somewhere: the wallet is a
-- ledger balance, health is a health sheet, heat is a standing score, the crew
-- is a roster, the account is a bank account. What did not exist was a way to
-- ask for all of it at once, and a heads-up display that had to send six
-- requests to draw one corner of the screen would send them every second.
--
-- So this composes, and composes only. It creates nothing, changes nothing and
-- decides nothing. Every field is read from whichever system owns it, and a
-- system that is not installed simply contributes no field rather than an
-- error, because a server that runs without gangs should not have a phone that
-- crashes asking about one.
--
-- It reads the acting character and takes no argument naming anybody, so there
-- is no way to ask it about somebody else.

local Money = require("domain.money")
local Characters = require("systems.characters")
local Property = require("systems.property")

local Overview = {}

function Overview.system(opts)
    opts = opts or {}

    return {
        name = "overview",
        requires = { "characters" },
        install = function(world)
            local people = world:repository(Characters.Character)

            --- Everything about one person that a display wants. Safe to call
            --- on a tick: it reads, it does not walk collections.
            local function look(character)
                local person = people:load(character)
                if not person then return nil end
                local services = world.services

                local out = {
                    character = character,
                    name = Characters.full_name(person),
                    state = person.state,
                    at = world.clock:describe(),
                    wallet = world.ledger:balance(Characters.wallet(character)):to_minor(),
                }

                if services.health then
                    local status = services.health.status(character)
                    out.hp = status.hp
                    out.condition = status.state
                end
                if services.standing then
                    out.heat = services.standing:heat(character)
                end
                if services.banking then
                    local accounts = services.banking.held_by(character)
                    if accounts[1] then
                        out.bank = services.banking.balance_of(accounts[1]):to_minor()
                        out.account = accounts[1]:get("number")
                    end
                end
                if services.phone then
                    out.phone = services.phone.number_of(character)
                end
                if services.gangs then
                    local crew = services.gangs.crew_of(character)
                    if crew then
                        out.crew = crew:get("name")
                        out.crew_tag = crew:get("tag")
                        out.crew_rank = services.gangs.rank_of(crew, character)
                    end
                end
                if services.police then
                    if services.police.is_officer(character) then
                        out.officer = true
                        out.on_duty = services.police.is_on_duty(character)
                    end
                    local held = services.police.detained_until(character)
                    if held then out.detained_until = held end
                end
                if services.admin and services.admin.level_of(character) > 0 then
                    out.staff = services.admin.level_of(character)
                end
                if services.work then
                    local shift = services.work.open_shift_of(character)
                    if shift then
                        out.working = shift:get("job")
                        out.shift_started = shift:get("started")
                    end
                end
                if services.inventory then
                    local space = services.inventory:space(character)
                    out.carrying = space.weight_used
                    out.capacity = space.weight
                    out.slots_used = space.slots_used
                    out.slots = space.slots
                end
                return out
            end

            world.services.overview = { look = look }

            world:define("me.status", {
                read_only = true,
                summary = "how you are doing, in one answer",
                -- Drawn on a heads-up display, so it is asked for often. The
                -- limit is generous and still a limit.
                rate = { per_minute = 120 },
                -- No argument naming anybody. There is no way to ask this
                -- about somebody else.
                args = {},
                handler = function(ctx)
                    if not ctx.actor then return ctx.refuse("not_playing", "You are not playing anybody.") end
                    local found = look(ctx.actor)
                    if not found then return ctx.refuse("no_such_person", "You are nobody.") end
                    return ctx.ok(found)
                end,
            })

            --- What is close enough to walk up to.
            ---
            --- Every screen past the first one needs this. A shop counter has
            --- to know which shop, and a stash has to know which house, and
            --- until now the only way to name either was to already know its
            --- id -- which is fine in a chat command and useless on a screen.
            ---
            --- Whether something is near is decided here, from the server's
            --- own copy of where everybody is standing. The client never says
            --- how far away it is: a client that could would stand next to
            --- every shop in the city at once.
            world:define("me.nearby", {
                read_only = true,
                summary = "what is close enough to walk up to",
                rate = { per_minute = 60 },
                args = {},
                handler = function(ctx)
                    if not ctx.actor then return ctx.refuse("not_playing", "You are not playing anybody.") end
                    local near = { shops = {}, places = {} }
                    local close = world.services.proximity
                    -- Outside a game there is nowhere to stand, so nothing is
                    -- near. That is the honest answer, not an error.
                    if not close then return ctx.ok(near) end

                    if world.services.shops then
                        local shops = world.services.shops.shops
                        shops:all()
                        for _, shop in ipairs(shops:where(function() return true end)) do
                            -- A shop is near when the premises it trades from
                            -- are near. Asked about its own id this was always
                            -- false: `position_of` knows where a prp, a veh, a
                            -- trf and a chr are, and a shp is none of those, so
                            -- it answered nil and proximity answered no.
                            --
                            -- Nothing failed. `nearby` simply never listed a
                            -- shop, and since it is the only thing that tells a
                            -- player a shop id, the counter could not be found,
                            -- and shop.list, shop.buy and shop.sell could not be
                            -- reached at all in ordinary play. `shop_at` in
                            -- systems/shops.lua had it right all along, and this
                            -- now asks the same question it does.
                            if close(ctx.actor, shop:get("place")) then
                                near.shops[#near.shops + 1] = {
                                    shop = shop.id,
                                    name = shop:get("name"),
                                    state = shop.state,
                                }
                            end
                        end
                        table.sort(near.shops, function(a, b) return a.shop < b.shop end)
                    end

                    if world.services.property then
                        local property = world.services.property
                        property.places:all()
                        for _, place in ipairs(property.places:where(function() return true end)) do
                            if close(ctx.actor, place.id) then
                                -- Whether it can be bought is the same
                                -- question property.buy asks, and it is two
                                -- facts rather than one: a place that was
                                -- bought keeps the price it was bought at and
                                -- is not on the market any more.
                                --
                                -- This is the only thing that ever tells a
                                -- player an address exists, and it said what
                                -- the door was called and not what it cost. So
                                -- a flat on the market for $2,500 was drawn
                                -- exactly like one somebody already lived in,
                                -- the screen offered to walk in rather than to
                                -- buy, and the only way to learn either was to
                                -- read the page's own JavaScript.
                                local for_sale = place:get("for_sale") == true
                                    and place.state ~= "owned"
                                near.places[#near.places + 1] = {
                                    place = place.id,
                                    address = place:get("address"),
                                    kind = place:get("kind"),
                                    mine = property.holder(place.id) == ctx.actor,
                                    -- A count to draw, never permission. Whether
                                    -- this person gets in is answered by
                                    -- property.enter refusing.
                                    may_enter = property.may_enter(place, ctx.actor) == true,
                                    -- Whether walking in is a thing that can
                                    -- happen here at all, which is not the
                                    -- same question as whether this person
                                    -- may. `may_enter` is false for a flat
                                    -- somebody else owns and true the day they
                                    -- buy it; it is false for a bank branch
                                    -- forever, for everybody, because a branch
                                    -- is premises and nobody lives in it.
                                    --
                                    -- The screen drew a Go in on both, so four
                                    -- of the seven rows in a seeded city
                                    -- offered a button `property.enter` refuses
                                    -- every single time. A control that cannot
                                    -- work is worse than an absent one: it
                                    -- reads as a broken product rather than a
                                    -- boundary.
                                    enterable = not Property.premises(place:get("kind")),
                                    for_sale = for_sale,
                                    -- A price where there is something to buy,
                                    -- and no price where there is not: what a
                                    -- place cost its owner is theirs.
                                    price = for_sale and place:get("price") or nil,
                                }
                            end
                        end
                        table.sort(near.places, function(a, b) return a.place < b.place end)
                    end
                    return ctx.ok(near)
                end,
            })

            --- Where the things a player can use actually are.
            ---
            --- `me.nearby` answers "what is within reach", which is only useful
            --- once you are already standing at it. Nothing answered "where is
            --- anything", so nothing could put a mark on a map or a light on
            --- the ground, and this resource drew neither: a player could not
            --- find a shop they had not been told the coordinates of.
            ---
            --- These are not secrets. A place is a building somebody can walk
            --- past, and the settings file that positions them belongs to the
            --- server owner. What is left out is anything about who owns what:
            --- that is `me.nearby`'s business, standing at the door.
            ---
            --- Read when a player spawns, soon after they buy or list a door,
            --- and every couple of minutes for what others did -- never on a
            --- tick. It was read once, on the reasoning that it changes only
            --- when the city is seeded, and a sold flat kept its mark and its
            --- price on everybody's map.
            ---
            --- Which is also why it answers somebody who is not playing anybody
            --- yet. The spawn comes before the character picker, so at the one
            --- moment the client asks, nobody is anybody. This refused them
            --- with not_playing, the client drew no marks, and nothing asked
            --- again: every player in every city got a map with nothing on it,
            --- while every check that asked the server itself saw a full one.
            --- Nothing here is about who is asking, so nothing needs them to be
            --- somebody.
            world:define("me.map", {
                summary = "where the things you can use are",
                rate = { per_minute = 6 },
                args = {},
                handler = function(ctx)
                    local out = {}
                    local property = world.services.property
                    if not property then return ctx.ok({ places = out }) end

                    -- A shop is not where the shop is; it is where the premises
                    -- it trades from are. Asking a shop for coordinates is the
                    -- mistake that made `me.nearby` list nothing for a year.
                    local counters = {}
                    if world.services.shops then
                        local shops = world.services.shops.shops
                        shops:all()
                        for _, shop in ipairs(shops:where(function() return true end)) do
                            counters[shop:get("place")] = { shop = shop.id, name = shop:get("name") }
                        end
                    end

                    property.places:all()
                    for _, place in ipairs(property.places:where(function() return true end)) do
                        local counter = counters[place.id]
                        local for_sale = place:get("for_sale") == true and place.state ~= "owned"
                        out[#out + 1] = {
                            place = place.id,
                            kind = place:get("kind"),
                            -- A shop's own name, where it has one: "Rob's
                            -- Liquor" is what somebody is looking for, not
                            -- "Rob's Liquor, Grove Street".
                            name = counter and counter.name or place:get("address"),
                            shop = counter and counter.shop or nil,
                            x = place:get("x"), y = place:get("y"), z = place:get("z"),
                            radius = place:get("radius"),
                            for_sale = for_sale,
                            price = for_sale and place:get("price") or nil,
                        }
                    end
                    table.sort(out, function(a, b) return a.place < b.place end)
                    return ctx.ok({ places = out })
                end,
            })

            world:define("me.pockets", {
                read_only = true,
                summary = "what you are carrying",
                rate = { per_minute = 60 },
                args = {},
                handler = function(ctx)
                    if not ctx.actor then return ctx.refuse("not_playing", "You are not playing anybody.") end
                    if not world.services.inventory then
                        return ctx.refuse("no_inventory", "Nothing is carried on this server.")
                    end
                    local lines = {}
                    for _, stack in ipairs(world.services.inventory:contents(ctx.actor)) do
                        local definition = world.services.items:get(stack.item)
                        lines[#lines + 1] = {
                            item = stack.item,
                            label = definition and definition.label or stack.item,
                            count = stack.count,
                            instance = stack.instance,
                        }
                    end
                    local space = world.services.inventory:space(ctx.actor)
                    -- The answer names the container it is describing. A
                    -- screen that has to remember which one it asked about is
                    -- a screen that can be wrong about it.
                    return ctx.ok({ container = ctx.actor, items = lines,
                                    weight = space.weight_used,
                                    capacity = space.weight, slots_used = space.slots_used,
                                    slots = space.slots })
                end,
            })
        end,
    }
end

Overview.Money = Money

return Overview
