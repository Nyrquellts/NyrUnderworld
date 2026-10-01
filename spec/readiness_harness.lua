-- Existing adapter wiring tests use real queue/lease semantics with measured
-- fake streaming facts. New readiness specs also drive unavailable facts.
local Readiness = require("adapter.readiness")
return function(env, opts)
    opts = opts or {}
    local gate = Readiness.new({ now = opts.now or function() return 0 end })
    local facts = { network = true, ped = true, collision = true, loading = false, switching = false }
    gate:set_session("fixture-epoch")
    local function sample() gate:observe(facts); gate:observe(facts) end
    sample()
    env.NyrReadiness = Readiness
    env.NyrWorldReady = function() return gate.ready end
    env.NyrWorldRevision = function() return gate.generation end
    env.NyrWhenWorldReady = function(send, fail) return gate:submit(send, fail or function() end) end
    env.NyrWorldSuspend = function() return gate:suspend() end
    env.NyrWorldLeaseCurrent = function(lease) return gate:current(lease) end
    env.NyrWorldRelease = function(lease)
        gate:release(lease)
        if opts.auto_sample ~= false then sample() end
    end
    env.GetGameTimer = opts.now or function() return 0 end
    env.RequestCollisionAtCoord = function() end
    env.HasCollisionLoadedAroundEntity = function() return facts.collision end
    return gate, facts, sample
end
