--- sampler.lua
--- Tick-level ring buffer sampler for entity properties.
--- Provides 5-second (300 tick) rolling averages to match the shortest
--- precision available in Factorio 1.1 (defines.flow_precision_index.five_seconds),
--- which is also what the electric network chart shows by default.
---
--- ARCHITECTURE:
---   - Registers script.on_nth_tick(1, ...) to sample every tick.
---     This is independent of script.on_event(on_tick) used by alerts/utils.
---   - Stores samples in global.energy_samples[unit_number][property][cursor].
---   - serialize.lua calls global.utils.get_sample_avg(entity, property)
---     to read the rolling average instead of the raw instantaneous value.
---
--- PROPERTIES SAMPLED (only those currently serialized that are instantaneous):
---   - "energy"                    : entity.energy (accumulator buffer fill, J)
---   - "energy_generated_last_tick": entity.energy_generated_last_tick (generator, J/tick)
---   - "fluidbox_flow_1"          : entity.fluidbox.get_flow(1) (pipe/pipe-to-ground, units/tick)
---   - "electric_output_flow_limit": entity.electric_output_flow_limit (solar panel, J/tick)
---   - "transfer_count"             : inserter held_stack transitions (items/tick)
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

local WINDOW_SIZE = 300  -- 5 seconds at 60 UPS

-- Initialize global storage if not present
if not global.energy_samples then
    global.energy_samples = {}
end
if not global.sample_cursor then
    global.sample_cursor = 0
end
if not global.sampled_entities then
    -- Set of unit_numbers we are actively sampling
    global.sampled_entities = {}
end
if not global.sample_running_sums then
    -- O(1) running sums: global.sample_running_sums[unit_number][property] = sum
    global.sample_running_sums = {}
end
if not global.inserter_prev_held then
    -- Previous tick's held_stack state per inserter: {name=string, count=number} or nil
    global.inserter_prev_held = {}
end
if not global.inserter_last_item then
    -- Name of the last item type transferred by each inserter
    global.inserter_last_item = {}
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
        props["electric_output_flow_limit"] = entity.electric_output_flow_limit or 0
    end
    if entity.type == "pipe" or entity.type == "pipe-to-ground" then
        local flow = 0
        if entity.fluidbox and #entity.fluidbox > 0 then
            pcall(function() flow = entity.fluidbox.get_flow(1) end)
        end
        props["fluidbox_flow_1"] = flow
    end
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

    return sums[property] / WINDOW_SIZE
end

--- The tick handler: sample all registered entities.
--- Uses script.on_nth_tick(1, ...) which is independent of
--- script.on_event(defines.events.on_tick, ...) used by alerts.lua and utils.lua.
---
--- Finds entities by type using find_entities_filtered. This is limited to
--- only the entity types we need (accumulators, generators, solar panels,
--- pipes) — typically a small set in any given base.
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
                local old = s["electric_output_flow_limit"][cursor] or 0
                local new = entity.electric_output_flow_limit or 0
                s["electric_output_flow_limit"][cursor] = new
                global.sample_running_sums[uid]["electric_output_flow_limit"] = (global.sample_running_sums[uid]["electric_output_flow_limit"] or 0) - old + new
            end
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
        end
    end

    -- Sample pipes and pipe-to-ground
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
        end
    end
end)
