--- Break a fix on purpose and see whether its spec notices.
--
-- "After fixing anything, mutate the fix and prove the test fails" is the rule
-- that has caught more tests asserting nothing than any review. It was done by
-- hand, a sed and a restore at a time, and a restore that was forgotten is a
-- defect committed on purpose. This does the loop: one mutation at a time, the
-- spec run, the file put back byte for byte whatever happened.
--
--   lua tools/mutate.lua <mutations.lua>
--
-- A mutations file returns a list of rows:
--
--   return {
--     { name = "rate limit reads city time", file = "core/world.lua",
--       old = [[rate_clock = function() return world.clock:real_elapsed() end,]],
--       new = [[rate_clock = city_now,]],
--       spec = "spec/world_spec.lua" },
--   }
--
-- `old` must occur in the file; a row whose `old` is not found is reported as
-- SKIP, never as caught. Line endings are matched either way. Write the file
-- with long brackets ([[ ]]) and write it with an editor, not a shell heredoc:
-- a shell that eats backslashes turns a mutation into one that never matches.
-- Exits 0 only when every mutation was caught.

local function read(path)
    local handle = assert(io.open(path, "rb"))
    local text = handle:read("a")
    handle:close()
    return text
end

local function write(path, text)
    local handle = assert(io.open(path, "wb"))
    handle:write(text)
    handle:close()
end

local function run(rows)
    local out = (os.getenv("TEMP") or os.getenv("TMPDIR") or ".") .. "/nyr-mutate.out"
    local caught, skipped, survived = 0, 0, {}
    for _, row in ipairs(rows) do
        local original = read(row.file)
        local old, new = row.old, row.new
        local from, to = original:find(old, 1, true)
        if not from and original:find("\r\n", 1, true) then
            old, new = old:gsub("\r?\n", "\r\n"), new:gsub("\r?\n", "\r\n")
            from, to = original:find(old, 1, true)
        end
        if not from then
            skipped = skipped + 1
            print(("SKIP     %s: `old` is not in %s"):format(row.name, row.file))
        else
            write(row.file, original:sub(1, from - 1) .. new .. original:sub(to + 1))
            local ok, spec_passed = pcall(os.execute, ('lua %s > "%s" 2>&1'):format(row.spec, out))
            write(row.file, original)
            if not ok then error(spec_passed) end
            if spec_passed then
                survived[#survived + 1] = row.name
                print(("SURVIVED %s"):format(row.name))
            else
                caught = caught + 1
                print(("caught   %s"):format(row.name))
            end
        end
    end
    print(("%d of %d mutations caught%s"):format(caught, #rows,
        skipped > 0 and (", %d skipped"):format(skipped) or ""))
    return caught == #rows
end

if (...) ~= "tools.mutate" then
    if not arg[1] then
        print("lua tools/mutate.lua <mutations.lua>")
        os.exit(2)
    end
    os.exit(run(dofile(arg[1])) and 0 or 1)
end

return { run = run }
