--- Every name a player can type or press, held apart.
---
--- This exists because two files claimed `nyrpockets` and nothing compared
--- them. FiveM keeps one handler per command name, so the clash was not two
--- things happening: it was one of them silently not happening, and which one
--- depended on the order `fxmanifest.lua` lists the files in. The text
--- formatter for `me.pockets` in `adapter/client.lua` had never run once, and
--- the only sign was a line in the game console nobody was reading.
---
--- Neither file can be loaded here. The names can.
local modname = ...
local lu = require("luaunit")
local Commands = require("adapter.commands")

TestPlayerCommands = {}

function TestPlayerCommands:test_no_name_is_claimed_twice()
    local clashes = Commands.clashes()
    local said = {}
    for _, clash in ipairs(clashes) do
        said[#said + 1] = ("%s (%s)"):format(clash.name, table.concat(clash.by, " and "))
    end
    lu.assertEquals(#clashes, 0,
        "a name claimed twice is one handler that never runs: " .. table.concat(said, ", "))
end

function TestPlayerCommands:test_the_check_would_notice_a_clash()
    -- A test that cannot fail is worse than no test, so the check is shown
    -- catching one rather than only ever agreeing that there are none.
    local typed = Commands.TYPED
    local kept = typed[#typed]
    typed[#typed + 1] = { Commands.PRESSED[1][1], "me.status", {} }
    local clashes = Commands.clashes()
    typed[#typed] = nil

    lu.assertEquals(#clashes, 1)
    lu.assertEquals(clashes[1].name, Commands.PRESSED[1][1])
    lu.assertEquals(clashes[1].by, { "pressed", "typed" })
    lu.assertEquals(typed[#typed], kept, "the table was not put back")
end

function TestPlayerCommands:test_the_screen_that_started_this_still_has_its_key()
    -- `nyrpockets` is the F3 screen and stays the F3 screen: a key mapping's
    -- name is what a player's rebinding is remembered against, so the clash
    -- was settled by moving the chat row instead.
    local pockets
    for _, row in ipairs(Commands.PRESSED) do
        if row[1] == "nyrpockets" then pockets = row end
    end
    lu.assertNotNil(pockets, "the pockets screen lost its command")
    lu.assertEquals(pockets[2], "pockets")
    lu.assertEquals(pockets[4], "F3")

    -- And the text listing is still reachable, under its own name.
    local carry
    for _, row in ipairs(Commands.TYPED) do
        if row[2] == "me.pockets" then carry = row end
    end
    lu.assertNotNil(carry, "nothing types its way to me.pockets any more")
    lu.assertEquals(carry[1], "nyrcarry")
end

function TestPlayerCommands:test_every_typed_row_is_a_name_a_command_and_arguments()
    for index, row in ipairs(Commands.TYPED) do
        local where = ("row %d"):format(index)
        lu.assertIsString(row[1], where .. " has no name")
        lu.assertStrMatches(row[1], "nyr%a+", nil, nil, where .. " is not a nyr command")
        lu.assertIsString(row[2], where .. " asks for nothing")
        lu.assertStrContains(row[2], ".", false, where .. " does not name a server command")
        lu.assertIsTable(row[3], where .. " does not say what arguments it takes")
        for _, field in ipairs(row[3]) do
            local name, kind = field:match("^([^:]+):?(.*)$")
            lu.assertNotNil(name, where .. " has an argument with no name")
            lu.assertTrue(kind == "" or kind == "int" or kind == "money" or kind == "rest",
                ("%s takes an argument of kind %q, which nothing converts"):format(where, kind))
        end
    end
end

-- ------------------------------------------------- what a typed word becomes

--- Money typed into chat is dollars, the same as money typed into a screen.
---
--- The bank's box was fixed on 2026-09-13 after somebody typed 200 and paid in
--- $2.00. Every chat command that moves money still sent the number it was
--- given as whole cents, because the arguments were converted in
--- `adapter/client.lua`, which nothing here can load: `/nyrlist <place> 3000`
--- put a flat on the market for $30.00, and a buyer paid that; `/nyrsend` with
--- 500 moved five dollars. The converting lives in `adapter/commands.lua` now,
--- beside the rows it reads.
TestTypedArguments = {}

local function typed(name)
    for _, row in ipairs(Commands.TYPED) do
        if row[1] == name then return row end
    end
    error("no typed command called " .. name)
end

function TestTypedArguments:test_money_typed_in_chat_is_dollars_and_arrives_as_cents()
    local args = Commands.args(typed("nyrlist")[3], { "prp_1", "3000" })
    lu.assertEquals(args, { place = "prp_1", price = 300000 })

    args = Commands.args(typed("nyrsend")[3], { "4412-0001", "500", "rent", "for", "May" })
    lu.assertEquals(args, { to = "4412-0001", amount = 50000, reference = "rent for May" })
    lu.assertEquals(math.type(args.amount), "integer")

    for name, words in pairs({
        nyrdeposit = { "prp_1", "200" }, nyrwithdraw = { "prp_1", "200" },
        nyrcrewin = { "200" }, nyrcrewout = { "200" },
        nyrgive = { "chr_1", "200", "a", "refund" }, nyrtakecash = { "chr_1", "200", "a", "mistake" },
    }) do
        lu.assertEquals(Commands.args(typed(name)[3], words).amount, 20000, name)
    end

    -- Cents are typed the way a price is written.
    lu.assertEquals(Commands.args(typed("nyrdeposit")[3], { "prp_1", "12.50" }).amount, 1250)
    lu.assertEquals(Commands.args(typed("nyrdeposit")[3], { "prp_1", "$1,200" }).amount, 120000)
end

function TestTypedArguments:test_every_amount_and_price_is_typed_as_money()
    -- The rule from the other end, so the next command that moves money cannot
    -- be added as a whole number of cents by copying a row.
    local wrong = {}
    for _, row in ipairs(Commands.TYPED) do
        for _, field in ipairs(row[3]) do
            local name, kind = field:match("^([^:]+):?(.*)$")
            if (name == "amount" or name == "price") and kind ~= "money" then
                wrong[#wrong + 1] = ("/%s %s:%s"):format(row[1], name, kind)
            end
        end
    end
    lu.assertEquals(wrong, {}, "money typed as something other than money")
end

function TestTypedArguments:test_chat_and_the_bank_screen_read_money_with_one_parser()
    -- Two doors, one reading. A second parser is a second place for 200 to
    -- mean two dollars.
    local NuiState = require("adapter.nui_state")
    for _, text in ipairs({ "200", "200.5", "200.50", "0.01", "$1,200.00", "0",
                            "much", "-5", "1.234", "1e3", "1,20", "$", ".5", "9999999999999" }) do
        local _, screen = NuiState.request("deposit", { branch = "prp_1", amount = text })
        local chat = Commands.args({ "amount:money" }, { text })
        lu.assertEquals(chat and chat.amount, type(screen) == "table" and screen.amount or nil, text)
    end
end

function TestTypedArguments:test_what_is_not_money_is_refused_before_it_is_sent_and_says_which()
    for _, bad in ipairs({ "much", "-5", "1.234", "2e2", "$" }) do
        local args, complaint = Commands.args(typed("nyrsend")[3], { "4412-0001", bad, "rent" })
        lu.assertNil(args, bad)
        lu.assertStrContains(complaint, "amount", false, bad)
        lu.assertStrContains(complaint, "12.50", false, bad)
    end
end

function TestTypedArguments:test_a_count_is_still_a_whole_number_and_the_rest_is_the_rest()
    lu.assertEquals(Commands.args(typed("nyrshopbuy")[3], { "shp_1", "water", "3" }),
        { shop = "shp_1", item = "water", count = 3 })
    local args, complaint = Commands.args(typed("nyrshopbuy")[3], { "shp_1", "water", "3.5" })
    lu.assertNil(args)
    lu.assertEquals(complaint, "count has to be a whole number")
    -- A word left out is not sent, and the server says whether it was needed.
    lu.assertEquals(Commands.args(typed("nyrlist")[3], { "prp_1" }), { place = "prp_1" })
    lu.assertEquals(Commands.args(typed("nyrtext")[3], { "555-1", "see", "you", "there" }),
        { to = "555-1", body = "see you there" })
end

function TestTypedArguments:test_the_client_converts_with_this_and_keeps_no_copy()
    -- A check tested against a copy of itself is not tested: the conversion the
    -- client runs has to be the one above.
    local text = assert(io.open("adapter/client.lua")):read("a")
    lu.assertStrContains(text, ".args(spec, words)")
    lu.assertNil(text:find("tointeger", 1, true), "adapter/client.lua converts typed words itself")
end

function TestPlayerCommands:test_every_screen_row_names_a_screen_a_line_and_a_key()
    -- Five screens are opened by a key. The other three -- a shop counter, a
    -- stash and a bank -- are reached by walking to them, because all three
    -- need to know which one and a key cannot say which. Work is on a key
    -- precisely because it has no location to walk to.
    local screens = {}
    for _, row in ipairs(Commands.PRESSED) do
        lu.assertIsString(row[1])
        lu.assertIsString(row[2])
        lu.assertStrContains(row[3], "NYR:", false, "the line a player reads does not say whose it is")
        lu.assertIsString(row[4])
        lu.assertNil(screens[row[2]], ("two keys open %s"):format(row[2]))
        screens[row[2]] = true
    end
    lu.assertEquals(#Commands.PRESSED, 5)
end

-- ------------------------------------------ what the server will accept

TestAllowed = {}

--- What the reach check found, as one line to read in a failure.
local function said(found)
    local lines = {}
    for _, row in ipairs(found) do
        lines[#lines + 1] = ("%s asks for %s"):format(row.how, row.command)
    end
    return table.concat(lines, ", ")
end

--- Every action the drawn page may ask for, in the shape the check takes.
local function pressed_actions()
    local NuiState = require("adapter.nui_state")
    local out = {}
    for action, declared in pairs(NuiState.ACTIONS) do
        out[#out + 1] = { how = action, command = declared.command }
    end
    return out
end

function TestAllowed:test_everything_a_player_can_type_is_something_the_server_accepts()
    -- A command missing from the allowlist is refused however valid it is, and
    -- the refusal says "that is not something you can ask for" -- which reads
    -- like the command does not exist. It has happened twice: the picker's
    -- first read, which drew a black screen, and `/nyrjobs`, which was refused
    -- while `work.list` sat defined and working.
    lu.assertEquals(said(Commands.unreachable()), "",
        "typed and then refused as unaskable")
end

function TestAllowed:test_everything_the_drawn_interface_asks_for_is_accepted_too()
    -- The page goes through the same bridge and the same allowlist. It is
    -- checked here rather than in nui_spec because the list is here.
    lu.assertEquals(said(Commands.unreachable(pressed_actions())), "",
        "the interface asks for what the server refuses")
end

function TestAllowed:test_the_check_would_notice_one_going_missing()
    -- The same function the assertions above call, shown catching one. Written
    -- with a loop of its own first, which meant breaking the real check changed
    -- nothing and every test still passed.
    local typed = Commands.TYPED
    typed[#typed + 1] = { "nyrsomething", "nothing.defined", {} }
    local found = Commands.unreachable()
    typed[#typed] = nil

    lu.assertEquals(#found, 1, "a command absent from the allowlist was not noticed")
    lu.assertEquals(found[1].how, "/nyrsomething")
    lu.assertEquals(found[1].command, "nothing.defined")
end

function TestAllowed:test_it_notices_the_drawn_interface_too()
    local found = Commands.unreachable({
        { how = "invent", command = "nothing.defined" },
    })
    lu.assertEquals(#found, 1)
    lu.assertEquals(found[1].how, "invent")
end

function TestAllowed:test_the_list_names_nothing_twice()
    local seen = {}
    for _, name in ipairs(Commands.ALLOWED) do
        lu.assertNil(seen[name], ("%s is on the allowlist twice"):format(name))
        seen[name] = true
        lu.assertStrContains(name, ".", false, ("%s is not a server command"):format(name))
    end
end

if modname == nil then os.exit(lu.LuaUnit.run()) end
