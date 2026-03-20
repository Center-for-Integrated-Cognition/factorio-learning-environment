--- sampler.lua
--- Tick-level ring buffer sampler for entity properties.
--- Provides a rolling average over a configurable window (default 30 seconds /
--- 1800 ticks at 60 UPS) — long enough to cover at least 2 full crafting
--- cycles of the slowest fluid-processing recipes (e.g. advanced oil
--- processing at 5 seconds per craft).
---
--- ARCHITECTURE:
---   - Registers script.on_nth_tick(1, ...) to sample every tick.
---     This is independent of script.on_event(on_tick) used by alerts/utils.
---   - Stores samples in global.energy_samples[unit_number][property][cursor].
---   - serialize.lua calls global.utils.get_sample_avg(entity, property)
---     to read the rolling average instead of the raw instantaneous value.
---
--- CONFIGURABLE WINDOW SIZE:
---   The window size defaults to 1800 ticks (30 s) and is stored in
---   global.sampler_window_size.  It can be changed at runtime from Python
---   (or any RCON client) without restarting the game:
---
---     -- via RCON (e.g. from export_scenario_model.py --sampler-window-seconds)
---     /sc global.utils.set_sampler_window_size(600)   -- 10 seconds
---
---   set_sampler_window_size(ticks) reinitialises all existing ring buffers,
---   pre-filling them with the current rolling average so there is no
---   cold-start drag.  The cursor is reset to 0.
---
--- PROPERTIES SAMPLED (only those currently serialized that are instantaneous):
---   - "energy"                    : entity.energy (accumulator buffer fill, J)
---   - "energy_generated_last_tick": entity.energy_generated_last_tick (generator, J/tick)
---   - "fluidbox_flow_N"          : entity.fluidbox.get_flow(N) (all fluidbox slots, units/tick)
---   - "electric_output_flow_limit": entity.electric_output_flow_limit (solar panel, J/tick)
---   - "transfer_count"             : inserter held_stack transitions (items/tick)
---   - "is_working"                : 1 if entity.status is a working status, 0 otherwise
---                                    (rolling avg = utilization ratio 0.0-1.0)
---
--- NOTE: electric pole flow_rate uses Factorio's built-in get_flow_count()
---   averaging, NOT this sampler. Both use a 5-second window.
---
--- NOTE: Static prototype values (max_energy_usage, max_power_output, etc.)
---   do NOT need averaging — they are constants.
---
--- ============================================================================
--- FUTURE: Arbitrary-resolution historical queries
--- ============================================================================
--- An agent could query data over a custom past window at any resolution
--- (even per-tick) without changing the default 5-second average. Here's what
--- it would take for each data source:
---
--- 1. ELECTRIC POLES (network statistics via LuaFlowStatistics)
---    The API already supports this natively via the `sample_index` parameter
---    on get_flow_count():
---
---      stats.get_flow_count{
---        name      = "steam-engine",
---        input     = true,
---        precision_index = defines.flow_precision_index.five_seconds,
---        sample_index    = 1   -- 1 = most recent, 300 = oldest
---      }
---
---    Each precision level stores exactly 300 samples. The time span per
---    sample depends on the precision:
---      five_seconds  → 5s / 300  = 16.7ms ≈ 1 tick per sample
---      one_minute    → 60s / 300 = 0.2s   = 12 ticks per sample
---      ten_minutes   → 600s/ 300 = 2s     = 120 ticks per sample
---      (etc.)
---
---    So at five_seconds precision, sample_index effectively gives per-tick
---    resolution over the last 5 seconds (300 ticks = 300 samples).
---
---    To implement: expose a Soar action or RCON command like
---      get_pole_history(unit_number, precision, from_sample, to_sample)
---    that iterates sample_index from `from_sample` to `to_sample` and
---    returns the array. The agent picks the precision and range.
---    Return values are already normalized to per-tick by the API.
---
--- 2. SAMPLED ENTITIES (accumulators, generators, solar panels, pipes)
---    Our ring buffer already stores per-tick values in:
---      global.energy_samples[unit_number][property][1..WINDOW_SIZE]
---    with global.sample_cursor pointing to the most-recently-written slot.
---
---    To implement: expose a function like
---      get_sample_history(entity, property, num_ticks)
---    that reads the ring buffer backwards from the cursor for `num_ticks`
---    entries (up to WINDOW_SIZE), returning the raw per-tick array.
---    The agent can then compute any aggregate it wants (min, max, avg
---    over any sub-window, detect transitions, etc.).
---
---    Example implementation sketch (NOT active):
---      global.utils.get_sample_history = function(entity, property, n)
---          local uid = entity.unit_number
---          local buf = global.energy_samples[uid]
---                      and global.energy_samples[uid][property]
---          if not buf then return {} end
---          n = math.min(n or WINDOW_SIZE, WINDOW_SIZE)
---          local result = {}
---          for i = 0, n - 1 do
---              local idx = ((global.sample_cursor - 1 - i) % WINDOW_SIZE) + 1
---              result[i + 1] = buf[idx] or 0
---          end
---          return result  -- [1] = most recent, [n] = oldest
---      end
---
--- 3. INTEGRATION COST
---    - No changes to sampler.lua's tick handler needed — it already records
---      per-tick. WINDOW_SIZE could be increased for a longer history at the
---      cost of memory (each extra tick = one double per entity per property).
---    - A new Soar action or RCON command would need to be registered to
---      make either function callable by the agent.
---    - The agent would need to specify the query parameters (which entity,
---      which property, how many ticks back, which precision for poles).
---    - Return format: a Lua array serialized the same way get_entities
---      currently dumps entity tables (via dump() in serialize.lua).
--- ============================================================================

-- Factorio sometimes returns DBL_MAX (~1.7977e+308) instead of math.huge
-- (positive infinity) for unconstrained values like electric_output_flow_limit.
-- This helper detects both cases to prevent overflow when summing across the
-- ring buffer.  Also catches NaN for safety.
local function is_huge(v)
    return v ~= v or v >= 1e300 or v <= -1e300
end

-- Default window size: 30 seconds at 60 UPS.  Can be changed at runtime
-- via global.utils.set_sampler_window_size(ticks) from an RCON command.
if not global.sampler_window_size then
    global.sampler_window_size = 1800
end
local WINDOW_SIZE = global.sampler_window_size

-- Statuses that count as "working" (actively carrying out a process) for utilization tracking.
-- Checked via numeric comparison against defines.entity_status values.
local WORKING_STATUS_SET = {}
if defines and defines.entity_status then
    for _, key in ipairs({"working", "normal", "low_power", "charging", "discharging",
                          "launching_rocket", "preparing_rocket_for_launch",
                          "waiting_to_launch_rocket", "low_input_fluid"}) do
        if defines.entity_status[key] ~= nil then
            WORKING_STATUS_SET[defines.entity_status[key]] = true
        end
    end
end

-- Entity types that should have is_working tracked but are not already iterated
-- by other sampler loops (accumulators, generators, solar panels, inserters, drills, pipes).
local CRAFTING_ENTITY_TYPES = {
    "assembling-machine", "furnace", "lab", "rocket-silo",
    "reactor", "beacon", "boiler"
}

-- Initialize global storage.  We ALWAYS reset on script load to avoid stale
-- data from a previous session (the Factorio server may persist across
-- Python-side resets while entities are cleared and re-placed with recycled
-- unit_numbers).  The `if not` pattern was the original design but caused
-- corrupted running sums when stale buffers survived a game reset.
global.energy_samples = {}
global.sample_cursor = 0
global.sampled_entities = {}
global.sample_running_sums = {}
global.inserter_prev_held = {}
global.inserter_last_item = {}
global.drill_prev_progress = {}

-- ---------------------------------------------------------------------------
-- Global production flow tracking (force-level, not per-entity)
-- ---------------------------------------------------------------------------
-- Tracks per-tick deltas of force.item/fluid_production_statistics so that
-- global flows use the same 30s rolling window as all group-level flows.
-- Structure:
--   global.production_flow_ring[item_name]["produced"|"consumed"][cursor] = delta
--   global.production_flow_sums[item_name]["produced"|"consumed"] = running_sum
--   global.production_flow_prev["produced"|"consumed"][item_name] = cumulative_count
-- Reset production flow globals on load (same rationale as entity data above)
global.production_flow_ring = {}
global.production_flow_sums = {}
global.production_flow_prev = { produced = {}, consumed = {} }
--- Change the sampler window size at runtime.  Reinitialises every existing
--- ring buffer so that running sums stay consistent.
--- @param new_size number  New window size in ticks (e.g. 3600 = 60 s).
global.utils.set_sampler_window_size = function(new_size)
    if not new_size or new_size < 1 then return end
    new_size = math.floor(new_size)
    local old_size = global.sampler_window_size or 1800
    if new_size == old_size then return end

    global.sampler_window_size = new_size
    -- Update the upvalue used by the tick handler & helpers
    WINDOW_SIZE = new_size

    -- Reinitialise every registered entity's ring buffers.
    -- We cannot meaningfully remap old samples into a differently-sized
    -- buffer, so we simply pre-fill with the current running-average
    -- (best available estimate) to avoid a cold-start drag.
    for uid, props in pairs(global.energy_samples) do
        for prop, buf in pairs(props) do
            local old_sum = global.sample_running_sums[uid] and global.sample_running_sums[uid][prop]
            local fill = (old_sum and old_size > 0) and (old_sum / old_size) or 0
            global.energy_samples[uid][prop] = {}
            for i = 1, new_size do
                global.energy_samples[uid][prop][i] = fill
            end
            if not global.sample_running_sums[uid] then
                global.sample_running_sums[uid] = {}
            end
            global.sample_running_sums[uid][prop] = fill * new_size
        end
    end
    global.sample_cursor = 0
    log("[sampler] window size changed from " .. old_size .. " to " .. new_size .. " ticks")
end

--- Cache of solar panel max production per prototype name (J/tick).
--- Populated lazily by get_solar_max_production().
if not global.solar_max_production_cache then
    global.solar_max_production_cache = {}
end

--- Return the solar panel's rated maximum production in J/tick.
--- When electric_output_flow_limit is math.huge, the panel is producing at
--- this capacity (the network is not constraining it).
--- Tries multiple Factorio API properties with pcall and caches the result.
local function get_solar_max_production(entity)
    local name = entity.name
    if global.solar_max_production_cache[name] then
        return global.solar_max_production_cache[name]
    end

    -- 1. Try entity.prototype.max_energy_production (available in some Factorio builds)
    local ok, val = pcall(function() return entity.prototype.max_energy_production end)
    if ok and val and type(val) == "number" and val > 0 and not is_huge(val) then
        global.solar_max_production_cache[name] = val
        log("[sampler] solar max production for '" .. name .. "' from max_energy_production: " .. val .. " J/tick")
        return val
    end

    -- 2. Try electric_energy_source_prototype.output_flow_limit
    local ok2, val2 = pcall(function()
        return entity.prototype.electric_energy_source_prototype.output_flow_limit
    end)
    if ok2 and val2 and type(val2) == "number" and val2 > 0 and not is_huge(val2) then
        global.solar_max_production_cache[name] = val2
        log("[sampler] solar max production for '" .. name .. "' from eesp.output_flow_limit: " .. val2 .. " J/tick")
        return val2
    end

    -- 3. Hardcoded fallback: standard solar-panel = 60kW = 1000 J/tick
    local fallback = 1000
    global.solar_max_production_cache[name] = fallback
    log("[sampler] solar max production for '" .. name .. "' using fallback: " .. fallback .. " J/tick")
    return fallback
end

-- Expose as global utility so serialize.lua can call it
global.utils.get_solar_max_production = get_solar_max_production

--- Return global production/consumption flow rates from the rolling window.
--- Rates are in items-per-tick (caller multiplies by 60 to get per-second).
--- @return table {produced={[name]=rate,...}, consumed={[name]=rate,...}}
global.utils.get_global_flow_rates = function()
    local result = { produced = {}, consumed = {} }
    for name, sums in pairs(global.production_flow_sums) do
        local prod = (sums.produced or 0) / WINDOW_SIZE
        local cons = (sums.consumed or 0) / WINDOW_SIZE
        if prod > 1e-12 then result.produced[name] = prod end
        if cons > 1e-12 then result.consumed[name] = cons end
    end
    return result
end

--- Diagnostic: dump ring buffer state for a given unit_number.
--- Returns a table with window_size, cursor, and per-property stats
--- (running_sum, computed_sum, buffer_len, min, max, avg) so that
--- the caller can verify the running sum is consistent with the buffer.
--- Usage from RCON:
---   /sc rcon.print(serpent.line(global.utils.debug_sampler_state(166)))
global.utils.debug_sampler_state = function(uid)
    local result = {
        window_size = WINDOW_SIZE,
        global_window_size = global.sampler_window_size,
        cursor = global.sample_cursor,
        entity_registered = global.sampled_entities[uid] or false,
        properties = {}
    }
    local samples = global.energy_samples[uid]
    local sums = global.sample_running_sums[uid]
    if not samples then
        result.error = "no samples for uid " .. tostring(uid)
        return result
    end
    for prop, buf in pairs(samples) do
        local running_sum = sums and sums[prop] or 0
        -- Recompute sum from buffer to check consistency
        local computed_sum = 0
        local buf_len = 0
        local buf_min = math.huge
        local buf_max = -math.huge
        for i = 1, WINDOW_SIZE do
            local v = buf[i] or 0
            computed_sum = computed_sum + v
            if v < buf_min then buf_min = v end
            if v > buf_max then buf_max = v end
            buf_len = buf_len + 1
        end
        result.properties[prop] = {
            running_sum = running_sum,
            computed_sum = computed_sum,
            drift = running_sum - computed_sum,
            buf_len = buf_len,
            buf_min = buf_min,
            buf_max = buf_max,
            avg = running_sum / WINDOW_SIZE,
            computed_avg = computed_sum / WINDOW_SIZE,
        }
    end
    return result
end
--- Register an entity for sampling. Called lazily the first time
--- serialize.lua encounters an entity that needs averaging.
global.utils.register_for_sampling = function(entity)
    if not entity or not entity.valid or not entity.unit_number then return end
    local uid = entity.unit_number
    if global.energy_samples[uid] then return end  -- already registered

    global.energy_samples[uid] = {}
    global.sampled_entities[uid] = true

    -- Pre-fill the ring buffer with the current value so the average
    -- is reasonable immediately (not dragged down by zeros).
    local props = {}
    if entity.type == "accumulator" then
        props["energy"] = entity.energy or 0
    elseif entity.type == "generator" then
        props["energy_generated_last_tick"] = entity.energy_generated_last_tick or 0
    elseif entity.type == "solar-panel" then
        -- Factorio reports math.huge for electric_output_flow_limit when the
        -- network doesn't constrain the panel.  This means the panel IS
        -- producing at its full rated capacity, so clamp to that value.
        local solar_val = entity.electric_output_flow_limit or 0
        if is_huge(solar_val) then
            solar_val = get_solar_max_production(entity)
        end
        props["electric_output_flow_limit"] = solar_val
    end
    -- Register all fluidbox slots for any entity with a fluidbox.
    -- This covers pipes (single slot), assembling-machines (oil-refinery,
    -- chemical-plant), mining-drills (pumpjack), boilers, generators, etc.
    if entity.fluidbox and #entity.fluidbox > 0 then
        for i = 1, #entity.fluidbox do
            local prop = "fluidbox_flow_" .. i
            local flow = 0
            pcall(function() flow = entity.fluidbox.get_flow(i) end)
            props[prop] = flow
        end
    end
    -- All entity types get is_working tracking (utilization)
    local initial_working = (entity.status and WORKING_STATUS_SET[entity.status]) and 1 or 0
    props["is_working"] = initial_working
    if entity.type == "inserter" then
        props["transfer_count"] = 0
        -- Initialize previous held_stack state
        local held = entity.held_stack
        if held and held.valid_for_read then
            global.inserter_prev_held[uid] = {name = held.name, count = held.count}
        else
            global.inserter_prev_held[uid] = nil
        end
    end
    if entity.type == "mining-drill" then
        props["mining_output_count"] = 0
        -- Initialize previous mining_progress
        global.drill_prev_progress[uid] = entity.mining_progress or 0
    end

    global.sample_running_sums[uid] = {}
    for prop, val in pairs(props) do
        global.energy_samples[uid][prop] = {}
        for i = 1, WINDOW_SIZE do
            global.energy_samples[uid][prop][i] = val
        end
        global.sample_running_sums[uid][prop] = val * WINDOW_SIZE
    end
end

--- Get the rolling average for a property of an entity.
--- If the entity hasn't been registered yet, registers it and returns
--- the current instantaneous value as a fallback.
global.utils.get_sample_avg = function(entity, property)
    if not entity or not entity.valid or not entity.unit_number then return 0 end
    local uid = entity.unit_number

    -- Lazy registration
    if not global.energy_samples[uid] then
        global.utils.register_for_sampling(entity)
    end

    local sums = global.sample_running_sums[uid]
    if not sums or not sums[property] then return 0 end

    local avg = sums[property] / WINDOW_SIZE
    -- Guard against non-finite results (NaN or inf from corrupted running sums)
    if is_huge(avg) then
        return 0
    end
    return avg
end

--- Update the is_working property for one entity in the ring buffer.
--- Called from each entity-type loop in the tick handler.
local function update_is_working(entity, uid, cursor)
    local s = global.energy_samples[uid]
    if not s or not s["is_working"] then return end
    local new = (entity.status and WORKING_STATUS_SET[entity.status]) and 1 or 0
    local old = s["is_working"][cursor] or 0
    s["is_working"][cursor] = new
    global.sample_running_sums[uid]["is_working"] = (global.sample_running_sums[uid]["is_working"] or 0) - old + new
end

--- The tick handler: sample all registered entities.
--- Uses script.on_nth_tick(1, ...) which is independent of
--- script.on_event(defines.events.on_tick, ...) used by alerts.lua and utils.lua.
---
--- Finds entities by type using find_entities_filtered for each category:
--- accumulators, generators, solar panels, pipes, and fluid-processing
--- buildings (assembling-machines, mining-drills, boilers, etc.).
script.on_nth_tick(1, function(event)
    -- Advance the ring buffer cursor (1-indexed, wraps around WINDOW_SIZE)
    global.sample_cursor = (global.sample_cursor % WINDOW_SIZE) + 1
    local cursor = global.sample_cursor

    local surface = game.surfaces[1]
    if not surface then return end

    -- Sample accumulators
    for _, entity in pairs(surface.find_entities_filtered{type="accumulator", force="player"}) do
        if entity.valid and entity.unit_number then
            local uid = entity.unit_number
            if not global.energy_samples[uid] then
                global.utils.register_for_sampling(entity)
            end
            local s = global.energy_samples[uid]
            if s and s["energy"] then
                local old = s["energy"][cursor] or 0
                local new = entity.energy or 0
                s["energy"][cursor] = new
                global.sample_running_sums[uid]["energy"] = (global.sample_running_sums[uid]["energy"] or 0) - old + new
            end
            update_is_working(entity, uid, cursor)
        end
    end

    -- Sample generators
    for _, entity in pairs(surface.find_entities_filtered{type="generator", force="player"}) do
        if entity.valid and entity.unit_number then
            local uid = entity.unit_number
            if not global.energy_samples[uid] then
                global.utils.register_for_sampling(entity)
            end
            local s = global.energy_samples[uid]
            if s and s["energy_generated_last_tick"] then
                local old = s["energy_generated_last_tick"][cursor] or 0
                local new = entity.energy_generated_last_tick or 0
                s["energy_generated_last_tick"][cursor] = new
                global.sample_running_sums[uid]["energy_generated_last_tick"] = (global.sample_running_sums[uid]["energy_generated_last_tick"] or 0) - old + new
            end
            update_is_working(entity, uid, cursor)
        end
    end

    -- Sample solar panels
    for _, entity in pairs(surface.find_entities_filtered{type="solar-panel", force="player"}) do
        if entity.valid and entity.unit_number then
            local uid = entity.unit_number
            if not global.energy_samples[uid] then
                global.utils.register_for_sampling(entity)
            end
            local s = global.energy_samples[uid]
            if s and s["electric_output_flow_limit"] then
                local new = entity.electric_output_flow_limit or 0
                -- Factorio may return math.huge OR DBL_MAX (~1.798e+308) when
                -- the network doesn't constrain the panel.  Clamp to rated max.
                if is_huge(new) then
                    new = get_solar_max_production(entity)
                end
                local old = s["electric_output_flow_limit"][cursor] or 0
                -- Clamp stale huge values left in the buffer
                if is_huge(old) then
                    old = 0
                end
                s["electric_output_flow_limit"][cursor] = new
                local sum = (global.sample_running_sums[uid]["electric_output_flow_limit"] or 0) - old + new
                -- Guard against corrupted running sum
                if is_huge(sum) then
                    sum = new * WINDOW_SIZE
                end
                global.sample_running_sums[uid]["electric_output_flow_limit"] = sum
            end
            update_is_working(entity, uid, cursor)
        end
    end

    -- Sample inserters: detect held_stack transitions (item held → empty = completed transfer)
    for _, entity in pairs(surface.find_entities_filtered{type="inserter", force="player"}) do
        if entity.valid and entity.unit_number then
            local uid = entity.unit_number
            if not global.energy_samples[uid] then
                global.utils.register_for_sampling(entity)
            end
            local s = global.energy_samples[uid]
            if s and s["transfer_count"] then
                local held = entity.held_stack
                local currently_holding = held and held.valid_for_read
                local prev = global.inserter_prev_held[uid]

                local items_this_tick = 0
                if prev and not currently_holding then
                    -- Transition: was holding → now empty = transfer completed
                    items_this_tick = prev.count or 1
                    global.inserter_last_item[uid] = prev.name
                end

                -- Update previous state
                if currently_holding then
                    global.inserter_prev_held[uid] = {name = held.name, count = held.count}
                else
                    global.inserter_prev_held[uid] = nil
                end

                -- Write to ring buffer with O(1) running sum update
                local old = s["transfer_count"][cursor] or 0
                s["transfer_count"][cursor] = items_this_tick
                global.sample_running_sums[uid]["transfer_count"] = (global.sample_running_sums[uid]["transfer_count"] or 0) - old + items_this_tick
            end
            update_is_working(entity, uid, cursor)
        end
    end

    -- Sample mining drills: detect mining_progress wrap-arounds (cycle completion)
    for _, entity in pairs(surface.find_entities_filtered{type="mining-drill", force="player"}) do
        if entity.valid and entity.unit_number then
            local uid = entity.unit_number
            if not global.energy_samples[uid] then
                global.utils.register_for_sampling(entity)
            end
            local s = global.energy_samples[uid]
            if s and s["mining_output_count"] then
                local current_progress = entity.mining_progress or 0
                local prev_progress = global.drill_prev_progress[uid]

                local items_this_tick = 0
                if prev_progress and prev_progress > 0.5 and current_progress < 0.1 then
                    -- mining_progress wrapped from near-1 to near-0: one mining cycle completed
                    items_this_tick = 1
                end

                global.drill_prev_progress[uid] = current_progress

                -- Write to ring buffer with O(1) running sum update
                local old = s["mining_output_count"][cursor] or 0
                s["mining_output_count"][cursor] = items_this_tick
                global.sample_running_sums[uid]["mining_output_count"] = (global.sample_running_sums[uid]["mining_output_count"] or 0) - old + items_this_tick
            end
            update_is_working(entity, uid, cursor)
        end
    end

    -- Sample all entities with fluidboxes.
    -- Pipes are the most common and always have exactly one slot, so we
    -- handle them with a direct property write (no inner loop) for speed.
    -- All other fluid-processing entity types use a generic N-slot loop.
    for _, entity in pairs(surface.find_entities_filtered{type={"pipe", "pipe-to-ground"}, force="player"}) do
        if entity.valid and entity.unit_number and entity.fluidbox and #entity.fluidbox > 0 then
            local uid = entity.unit_number
            if not global.energy_samples[uid] then
                global.utils.register_for_sampling(entity)
            end
            local s = global.energy_samples[uid]
            if s and s["fluidbox_flow_1"] then
                local flow = 0
                pcall(function() flow = entity.fluidbox.get_flow(1) end)
                local old = s["fluidbox_flow_1"][cursor] or 0
                s["fluidbox_flow_1"][cursor] = flow
                global.sample_running_sums[uid]["fluidbox_flow_1"] = (global.sample_running_sums[uid]["fluidbox_flow_1"] or 0) - old + flow
            end
            -- Note: pipes don't get is_working — they don't have a meaningful status
        end
    end

    -- Sample crafting entities (assembling machines, furnaces, labs, etc.) for utilization only.
    -- These entity types don't have a type-specific metric sampled above, so we only track is_working.
    for _, etype in ipairs(CRAFTING_ENTITY_TYPES) do
        for _, entity in pairs(surface.find_entities_filtered{type=etype, force="player"}) do
            if entity.valid and entity.unit_number then
                local uid = entity.unit_number
                if not global.energy_samples[uid] then
                    global.utils.register_for_sampling(entity)
                end
                update_is_working(entity, uid, cursor)
            end
        end
    end

    -- Fluid-processing buildings: assembling-machine (oil-refinery,
    -- chemical-plant), mining-drill (pumpjack), boiler, generator, etc.
    local fluid_entity_types = {
        "assembling-machine", "mining-drill", "boiler", "generator",
        "offshore-pump", "storage-tank", "furnace"
    }
    for _, entity in pairs(surface.find_entities_filtered{type=fluid_entity_types, force="player"}) do
        if entity.valid and entity.unit_number and entity.fluidbox and #entity.fluidbox > 0 then
            local uid = entity.unit_number
            if not global.energy_samples[uid] then
                global.utils.register_for_sampling(entity)
            end
            local s = global.energy_samples[uid]
            if s then
                for i = 1, #entity.fluidbox do
                    local prop = "fluidbox_flow_" .. i
                    if s[prop] then
                        local flow = 0
                        pcall(function() flow = entity.fluidbox.get_flow(i) end)
                        local old = s[prop][cursor] or 0
                        s[prop][cursor] = flow
                        global.sample_running_sums[uid][prop] = (global.sample_running_sums[uid][prop] or 0) - old + flow
                    end
                end
            end
        end
    end
end)
