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
global.sample_prototype_data = {}  -- {uid -> {max_energy_usage, drain, fuel_value}}
global.sample_network_id = {}      -- {uid -> electric_network_id}
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
    -- Electricity consumers get actual_power tracking (requested × satisfaction)
    -- so min/max bounds capture the real variation the agent observes.
    local has_eesp = false
    pcall(function()
        has_eesp = entity.prototype.electric_energy_source_prototype ~= nil
    end)
    if has_eesp then
        props["actual_power"] = 0  -- filled each tick in the electricity pass
    end

    global.sample_running_sums[uid] = {}
    for prop, val in pairs(props) do
        global.energy_samples[uid][prop] = {}
        for i = 1, WINDOW_SIZE do
            global.energy_samples[uid][prop][i] = val
        end
        global.sample_running_sums[uid][prop] = val * WINDOW_SIZE
    end

    -- Store prototype data needed for derived stats (power_consumption,
    -- fuel_consumption_items).  We capture these at registration time so the
    -- stats-computation functions do not need to look up the entity again.
    local proto_data = { max_energy_usage = 0, drain = 0, fuel_value = 0 }
    pcall(function()
        if entity.prototype and entity.prototype.max_energy_usage then
            proto_data.max_energy_usage = entity.prototype.max_energy_usage
        end
    end)
    pcall(function()
        local eesp = entity.prototype.electric_energy_source_prototype
        if eesp and eesp.drain then proto_data.drain = eesp.drain end
    end)
    pcall(function()
        if entity.burner and entity.burner.currently_burning then
            proto_data.fuel_value = entity.burner.currently_burning.fuel_value or 0
        end
    end)
    global.sample_prototype_data[uid] = proto_data

    -- Store electric network ID for actual_power computation
    pcall(function()
        if entity.electric_network_id then
            global.sample_network_id[uid] = entity.electric_network_id
        end
    end)
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
    -- Eliminate IEEE -0.0 from running-sum drift (e.g. idle entities)
    if avg == 0 then return 0 end
    return avg
end

--- Return the minimum value within the rolling window for a given property.
--- O(WINDOW_SIZE) scan — only called at serialization time, not per-tick.
global.utils.get_sample_min = function(entity, property)
    if not entity or not entity.valid or not entity.unit_number then return 0 end
    local uid = entity.unit_number
    if not global.energy_samples[uid] then
        global.utils.register_for_sampling(entity)
    end
    local buf = global.energy_samples[uid]
    if not buf or not buf[property] then return 0 end
    local ring = buf[property]
    local result = math.huge
    for i = 1, WINDOW_SIZE do
        local v = ring[i]
        if v ~= nil and not is_huge(v) and v < result then
            result = v
        end
    end
    if result == math.huge then return 0 end
    return result
end

--- Return the maximum value within the rolling window for a given property.
--- O(WINDOW_SIZE) scan — only called at serialization time, not per-tick.
global.utils.get_sample_max = function(entity, property)
    if not entity or not entity.valid or not entity.unit_number then return 0 end
    local uid = entity.unit_number
    if not global.energy_samples[uid] then
        global.utils.register_for_sampling(entity)
    end
    local buf = global.energy_samples[uid]
    if not buf or not buf[property] then return 0 end
    local ring = buf[property]
    local result = -math.huge
    for i = 1, WINDOW_SIZE do
        local v = ring[i]
        if v ~= nil and not is_huge(v) and v > result then
            result = v
        end
    end
    if result == -math.huge then return 0 end
    return result
end

--- Dump the entire ring buffer for all registered entities and properties.
--- Returns a table keyed by unit_number, then by property name, containing
--- an array of all WINDOW_SIZE raw per-tick values ordered oldest→newest.
--- Intended for use by the export script (via RCON) to compute true min/max
--- bounds over the full buffer — NOT used during normal agent operation.
---
--- Usage from RCON / export script:
---   /sc rcon.print(game.table_to_json(global.utils.dump_all_sample_buffers()))
---
--- The returned table also includes metadata:
---   ._window_size = current WINDOW_SIZE
---   ._cursor      = current cursor position (1-indexed)
global.utils.dump_all_sample_buffers = function()
    local result = {
        _window_size = WINDOW_SIZE,
        _cursor = global.sample_cursor,
    }
    for uid, props in pairs(global.energy_samples) do
        result[tostring(uid)] = {}
        for prop, buf in pairs(props) do
            -- Read the ring buffer in chronological order (oldest → newest).
            -- The cursor points to the most recently written slot, so the
            -- oldest slot is cursor+1 (wrapping around).
            local ordered = {}
            for i = 1, WINDOW_SIZE do
                local idx = ((global.sample_cursor + i - 1) % WINDOW_SIZE) + 1
                ordered[i] = buf[idx] or 0
            end
            result[tostring(uid)][prop] = ordered
        end
    end
    return result
end

--- Dump the ring buffer for a single entity (by unit_number).
--- Same format as dump_all_sample_buffers but for one entity only.
--- Usage: /sc rcon.print(game.table_to_json(global.utils.dump_sample_buffer(166)))
global.utils.dump_sample_buffer = function(uid)
    local result = {
        _window_size = WINDOW_SIZE,
        _cursor = global.sample_cursor,
    }
    local props = global.energy_samples[uid]
    if not props then return result end
    for prop, buf in pairs(props) do
        local ordered = {}
        for i = 1, WINDOW_SIZE do
            local idx = ((global.sample_cursor + i - 1) % WINDOW_SIZE) + 1
            ordered[i] = buf[idx] or 0
        end
        result[prop] = ordered
    end
    return result
end

--- Compute per-entity, per-property statistics (min, max, sum, count)
--- directly in Lua, avoiding the massive JSON serialization of raw buffers.
--- Returns {uid_str: {prop: {min=, max=, mean=, count=, n_unique=}}, _window_size=}
---
--- Usage: /sc rcon.print(game.table_to_json(global.utils.compute_buffer_stats()))
global.utils.compute_buffer_stats = function()
    local result = { _window_size = WINDOW_SIZE }
    for uid, props in pairs(global.energy_samples) do
        local entity_stats = {}
        for prop, buf in pairs(props) do
            local vmin = math.huge
            local vmax = -math.huge
            local vsum = 0
            local seen = {}
            local n_unique = 0
            for i = 1, WINDOW_SIZE do
                local v = buf[i] or 0
                if v < vmin then vmin = v end
                if v > vmax then vmax = v end
                vsum = vsum + v
                if not seen[v] then
                    seen[v] = true
                    n_unique = n_unique + 1
                end
            end
            entity_stats[prop] = {
                min = vmin,
                max = vmax,
                mean = vsum / WINDOW_SIZE,
                count = WINDOW_SIZE,
                n_unique = n_unique,
            }
        end
        -- Derive power_consumption and fuel_consumption_items from is_working
        if props["is_working"] then
            local pd = global.sample_prototype_data[uid]
            if pd and pd.max_energy_usage > 0 then
                local rated = pd.max_energy_usage  -- J/tick
                local drain = pd.drain or 0
                local iw_buf = props["is_working"]

                -- power_consumption: for electric consumers
                local pc_min = math.huge
                local pc_max = -math.huge
                local pc_sum = 0
                for i = 1, WINDOW_SIZE do
                    local iw = iw_buf[i] or 0
                    local pc = drain + (rated - drain) * iw
                    if pc < pc_min then pc_min = pc end
                    if pc > pc_max then pc_max = pc end
                    pc_sum = pc_sum + pc
                end
                entity_stats["power_consumption"] = {
                    min = pc_min,
                    max = pc_max,
                    mean = pc_sum / WINDOW_SIZE,
                    count = WINDOW_SIZE,
                    n_unique = entity_stats["is_working"] and entity_stats["is_working"].n_unique or 1,
                }

                -- fuel_consumption_items: for burner entities (boilers, etc.)
                if pd.fuel_value and pd.fuel_value > 0 then
                    local items_per_tick = rated / pd.fuel_value
                    local fc_min = math.huge
                    local fc_max = -math.huge
                    local fc_sum = 0
                    for i = 1, WINDOW_SIZE do
                        local iw = iw_buf[i] or 0
                        local fc = items_per_tick * iw
                        if fc < fc_min then fc_min = fc end
                        if fc > fc_max then fc_max = fc end
                        fc_sum = fc_sum + fc
                    end
                    entity_stats["fuel_consumption_items"] = {
                        min = fc_min,
                        max = fc_max,
                        mean = fc_sum / WINDOW_SIZE,
                        count = WINDOW_SIZE,
                        n_unique = entity_stats["is_working"] and entity_stats["is_working"].n_unique or 1,
                    }
                end
            end
        end
        result[tostring(uid)] = entity_stats
    end
    return result
end

--- Compute min/max of a sliding-window average over the ring buffer.
--- window_ticks: the agent's sampler window width in ticks.
--- The ring buffer must be larger than window_ticks (use set_sampler_window_size
--- to grow it before recording).
---
--- For each property, slides a window of window_ticks across the buffer
--- (in chronological order), maintaining a running sum.  Returns the
--- minimum and maximum window-average observed, plus the overall mean.
---
--- O(WINDOW_SIZE) per property — O(1) per tick position.
---
--- Usage: /sc rcon.print(game.table_to_json(global.utils.compute_sliding_window_stats(600)))
global.utils.compute_sliding_window_stats = function(window_ticks)
    local result = { _window_size = WINDOW_SIZE, _sliding_window = window_ticks }
    local cursor = global.sample_cursor
    for uid, props in pairs(global.energy_samples) do
        local entity_stats = {}
        for prop, buf in pairs(props) do
            -- Read buffer in chronological order into a flat array
            local vals = {}
            local total_sum = 0
            local seen = {}
            local n_unique = 0
            for i = 1, WINDOW_SIZE do
                local idx = ((cursor + i - 1) % WINDOW_SIZE) + 1
                local v = buf[idx] or 0
                vals[i] = v
                total_sum = total_sum + v
                if not seen[v] then
                    seen[v] = true
                    n_unique = n_unique + 1
                end
            end
            if WINDOW_SIZE < window_ticks then
                -- Not enough data; return whole-buffer stats
                local vmin = math.huge
                local vmax = -math.huge
                for i = 1, WINDOW_SIZE do
                    if vals[i] < vmin then vmin = vals[i] end
                    if vals[i] > vmax then vmax = vals[i] end
                end
                entity_stats[prop] = {
                    min = vmin,
                    max = vmax,
                    mean = total_sum / WINDOW_SIZE,
                    count = WINDOW_SIZE,
                    n_unique = n_unique,
                }
            else
                -- First window sum
                local win_sum = 0
                for i = 1, window_ticks do
                    win_sum = win_sum + vals[i]
                end
                local win_avg = win_sum / window_ticks
                local min_avg = win_avg
                local max_avg = win_avg
                -- Slide
                for i = window_ticks + 1, WINDOW_SIZE do
                    win_sum = win_sum + vals[i] - vals[i - window_ticks]
                    win_avg = win_sum / window_ticks
                    if win_avg < min_avg then min_avg = win_avg end
                    if win_avg > max_avg then max_avg = win_avg end
                end
                entity_stats[prop] = {
                    sliding_min = min_avg,
                    sliding_max = max_avg,
                    mean = total_sum / WINDOW_SIZE,
                    count = WINDOW_SIZE,
                    n_unique = n_unique,
                }
            end
        end
        -- Derive power_consumption and fuel_consumption_items sliding-window stats from is_working
        -- Derive power_consumption and fuel_consumption_items from is_working
        if props["is_working"] then
            local pd = global.sample_prototype_data[uid]
            if pd and pd.max_energy_usage > 0 then
                local rated = pd.max_energy_usage
                local drain = pd.drain or 0
                local iw_buf = props["is_working"]

                -- power_consumption: for electric consumers
                local pc_vals = {}
                local pc_total = 0
                for i = 1, WINDOW_SIZE do
                    local idx = ((cursor + i - 1) % WINDOW_SIZE) + 1
                    local iw = iw_buf[idx] or 0
                    local pc = drain + (rated - drain) * iw
                    pc_vals[i] = pc
                    pc_total = pc_total + pc
                end
                if WINDOW_SIZE < window_ticks then
                    local pc_min = math.huge
                    local pc_max = -math.huge
                    for i = 1, WINDOW_SIZE do
                        if pc_vals[i] < pc_min then pc_min = pc_vals[i] end
                        if pc_vals[i] > pc_max then pc_max = pc_vals[i] end
                    end
                    entity_stats["power_consumption"] = {
                        min = pc_min,
                        max = pc_max,
                        mean = pc_total / WINDOW_SIZE,
                        count = WINDOW_SIZE,
                        n_unique = entity_stats["is_working"] and entity_stats["is_working"].n_unique or 1,
                    }
                else
                    local win_sum = 0
                    for i = 1, window_ticks do
                        win_sum = win_sum + pc_vals[i]
                    end
                    local win_avg = win_sum / window_ticks
                    local min_avg = win_avg
                    local max_avg = win_avg
                    for i = window_ticks + 1, WINDOW_SIZE do
                        win_sum = win_sum + pc_vals[i] - pc_vals[i - window_ticks]
                        win_avg = win_sum / window_ticks
                        if win_avg < min_avg then min_avg = win_avg end
                        if win_avg > max_avg then max_avg = win_avg end
                    end
                    entity_stats["power_consumption"] = {
                        sliding_min = min_avg,
                        sliding_max = max_avg,
                        mean = pc_total / WINDOW_SIZE,
                        count = WINDOW_SIZE,
                        n_unique = entity_stats["is_working"] and entity_stats["is_working"].n_unique or 1,
                    }
                end

                -- fuel_consumption_items: for burner entities (boilers, etc.)
                if pd.fuel_value and pd.fuel_value > 0 then
                    local items_per_tick = rated / pd.fuel_value
                    local fc_vals = {}
                    local fc_total = 0
                    for i = 1, WINDOW_SIZE do
                        local idx = ((cursor + i - 1) % WINDOW_SIZE) + 1
                        local iw = iw_buf[idx] or 0
                        local fc = items_per_tick * iw
                        fc_vals[i] = fc
                        fc_total = fc_total + fc
                    end
                    if WINDOW_SIZE < window_ticks then
                        local fc_min = math.huge
                        local fc_max = -math.huge
                        for i = 1, WINDOW_SIZE do
                            if fc_vals[i] < fc_min then fc_min = fc_vals[i] end
                            if fc_vals[i] > fc_max then fc_max = fc_vals[i] end
                        end
                        entity_stats["fuel_consumption_items"] = {
                            min = fc_min,
                            max = fc_max,
                            mean = fc_total / WINDOW_SIZE,
                            count = WINDOW_SIZE,
                            n_unique = entity_stats["is_working"] and entity_stats["is_working"].n_unique or 1,
                        }
                    else
                        local win_sum = 0
                        for i = 1, window_ticks do
                            win_sum = win_sum + fc_vals[i]
                        end
                        local win_avg = win_sum / window_ticks
                        local fc_min_avg = win_avg
                        local fc_max_avg = win_avg
                        for i = window_ticks + 1, WINDOW_SIZE do
                            win_sum = win_sum + fc_vals[i] - fc_vals[i - window_ticks]
                            win_avg = win_sum / window_ticks
                            if win_avg < fc_min_avg then fc_min_avg = win_avg end
                            if win_avg > fc_max_avg then fc_max_avg = win_avg end
                        end
                        entity_stats["fuel_consumption_items"] = {
                            sliding_min = fc_min_avg,
                            sliding_max = fc_max_avg,
                            mean = fc_total / WINDOW_SIZE,
                            count = WINDOW_SIZE,
                            n_unique = entity_stats["is_working"] and entity_stats["is_working"].n_unique or 1,
                        }
                    end
                end
            end
        end
        result[tostring(uid)] = entity_stats
    end
    return result
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

-- ---------------------------------------------------------------------------
-- Cached entity tracker (replaces per-tick find_entities_filtered scans).
-- ---------------------------------------------------------------------------
-- global.tracked_entities[category] = { [unit_number] = entity, ... }
--
-- Categories match the buckets the tick handler iterates: one bucket per
-- find_entities_filtered call we replaced.  An entity may appear in more
-- than one bucket (e.g. a boiler is in 'fluid' AND 'crafting' for is_working,
-- a generator is in 'generator' for energy AND 'fluid' for fluidbox).
--
-- Membership is maintained incrementally via Factorio build/destroy events.
-- A bootstrap scan runs on the first tick to pick up entities that already
-- existed at scenario load (e.g. via add_entities / blueprints).
--
-- Categories:
--   accumulator   - type=accumulator
--   generator     - type=generator
--   solar         - type=solar-panel
--   inserter      - type=inserter
--   drill         - type=mining-drill
--   pipe          - type=pipe / pipe-to-ground
--   crafting      - type in CRAFTING_ENTITY_TYPES (assembling-machine, furnace, lab, ...)
--   fluid         - any of {assembling-machine, mining-drill, boiler, generator,
--                            offshore-pump, storage-tank, furnace} (for fluidbox loop)
-- ---------------------------------------------------------------------------
global.tracked_entities = global.tracked_entities or {
    accumulator = {},
    generator   = {},
    solar       = {},
    inserter    = {},
    drill       = {},
    pipe        = {},
    crafting    = {},
    fluid       = {},
}

-- Set of crafting entity types for fast lookup (used by classifier below).
local CRAFTING_TYPE_SET = {}
for _, t in ipairs(CRAFTING_ENTITY_TYPES) do CRAFTING_TYPE_SET[t] = true end

-- Set of fluid-loop entity types (must match the tick handler's old list).
local FLUID_ENTITY_TYPE_SET = {
    ["assembling-machine"] = true,
    ["mining-drill"]       = true,
    ["boiler"]             = true,
    ["generator"]          = true,
    ["offshore-pump"]      = true,
    ["storage-tank"]       = true,
    ["furnace"]            = true,
}

--- Add an entity to all tracker buckets it qualifies for.
--- Idempotent: re-adding the same uid is a no-op (overwrites with same entity ref).
local function tracker_add(entity)
    if not entity or not entity.valid or not entity.unit_number then return end
    if entity.force and entity.force.name ~= "player" then return end
    local uid = entity.unit_number
    local etype = entity.type
    local te = global.tracked_entities

    if etype == "accumulator" then te.accumulator[uid] = entity end
    if etype == "generator"   then te.generator[uid]   = entity end
    if etype == "solar-panel" then te.solar[uid]       = entity end
    if etype == "inserter"    then te.inserter[uid]    = entity end
    if etype == "mining-drill" then te.drill[uid]      = entity end
    if etype == "pipe" or etype == "pipe-to-ground" then te.pipe[uid] = entity end
    if CRAFTING_TYPE_SET[etype] then te.crafting[uid]  = entity end
    if FLUID_ENTITY_TYPE_SET[etype] then te.fluid[uid] = entity end
end

--- Remove an entity from all tracker buckets.
local function tracker_remove(uid)
    if not uid then return end
    local te = global.tracked_entities
    te.accumulator[uid] = nil
    te.generator[uid]   = nil
    te.solar[uid]       = nil
    te.inserter[uid]    = nil
    te.drill[uid]       = nil
    te.pipe[uid]        = nil
    te.crafting[uid]    = nil
    te.fluid[uid]       = nil
end

-- One-time bootstrap on first tick: scan the surface and populate the tracker
-- with any entities that already exist (placed via add_entities at scenario
-- load, blueprints applied before our event handlers were registered, etc.).
-- Cleared after running once.  Set true on every load so reloads still scan.
global.tracker_needs_bootstrap = true

local function tracker_bootstrap()
    local surface = game.surfaces[1]
    if not surface then return end
    -- One broad scan covering every type we care about.  This is a single
    -- O(surface) call paid once, replacing 10+ per-tick scans forever.
    local types = {
        "accumulator", "generator", "solar-panel", "inserter", "mining-drill",
        "pipe", "pipe-to-ground",
        "assembling-machine", "furnace", "lab", "rocket-silo", "reactor",
        "beacon", "boiler", "offshore-pump", "storage-tank",
    }
    for _, e in pairs(surface.find_entities_filtered{type=types, force="player"}) do
        tracker_add(e)
    end
    global.tracker_needs_bootstrap = false
end

-- Build/destroy event hooks to keep the tracker in sync.
-- Use a filter so we only get events for types we care about.
local TRACKED_FILTER = {
    {filter="type", type="accumulator"},
    {filter="type", type="generator"},
    {filter="type", type="solar-panel"},
    {filter="type", type="inserter"},
    {filter="type", type="mining-drill"},
    {filter="type", type="pipe"},
    {filter="type", type="pipe-to-ground"},
    {filter="type", type="assembling-machine"},
    {filter="type", type="furnace"},
    {filter="type", type="lab"},
    {filter="type", type="rocket-silo"},
    {filter="type", type="reactor"},
    {filter="type", type="beacon"},
    {filter="type", type="boiler"},
    {filter="type", type="offshore-pump"},
    {filter="type", type="storage-tank"},
}

local BUILD_EVENTS = {
    defines.events.on_built_entity,
    defines.events.on_robot_built_entity,
    defines.events.script_raised_built,
    defines.events.script_raised_revive,
}
local DESTROY_EVENTS = {
    defines.events.on_entity_died,
    defines.events.on_player_mined_entity,
    defines.events.on_robot_mined_entity,
    defines.events.script_raised_destroy,
}

local function on_tracked_built(event)
    local e = event.created_entity or event.entity
    if e then tracker_add(e) end
end

local function on_tracked_destroyed(event)
    local e = event.entity
    if e and e.unit_number then
        tracker_remove(e.unit_number)
        -- Also free per-entity sampler state so we don't leak memory.
        local uid = e.unit_number
        global.energy_samples[uid] = nil
        global.sample_running_sums[uid] = nil
        global.sample_prototype_data[uid] = nil
        global.sample_network_id[uid] = nil
        global.sampled_entities[uid] = nil
        global.inserter_prev_held[uid] = nil
        global.inserter_last_item[uid] = nil
        global.drill_prev_progress[uid] = nil
    end
end

for _, ev in ipairs(BUILD_EVENTS) do
    pcall(function() script.on_event(ev, on_tracked_built, TRACKED_FILTER) end)
end
for _, ev in ipairs(DESTROY_EVENTS) do
    pcall(function() script.on_event(ev, on_tracked_destroyed, TRACKED_FILTER) end)
end

--- The tick handler: sample all registered entities.
--- Uses script.on_nth_tick(1, ...) which is independent of
--- script.on_event(defines.events.on_tick, ...) used by alerts.lua and utils.lua.
---
--- Finds entities by type using find_entities_filtered for each category:
--- accumulators, generators, solar panels, pipes, and fluid-processing
--- buildings (assembling-machines, mining-drills, boilers, etc.).
script.on_nth_tick(1, function(event)
    -- Calibration short-circuit: when set via RCON
    --   /sc global.sampler_disabled = true
    -- the per-tick sampling loop becomes a no-op so external callers can
    -- measure raw engine UPS vs sampled UPS and back-calculate sampler cost.
    if global.sampler_disabled then return end
    -- Advance the ring buffer cursor (1-indexed, wraps around WINDOW_SIZE)
    global.sample_cursor = (global.sample_cursor % WINDOW_SIZE) + 1
    local cursor = global.sample_cursor

    local surface = game.surfaces[1]
    if not surface then return end

    -- One-time tracker bootstrap (entities present at scenario load).
    if global.tracker_needs_bootstrap then
        tracker_bootstrap()
    end

    -- Per-network production accumulator for the actual_power pass below.
    -- Filled in-place during the generator/solar loops to avoid a second
    -- find_entities_filtered scan per tick.
    local net_production = {}  -- network_id -> J/tick

    -- Sample accumulators
    for uid, entity in pairs(global.tracked_entities.accumulator) do
        if entity.valid then
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
    for uid, entity in pairs(global.tracked_entities.generator) do
        if entity.valid then
            if not global.energy_samples[uid] then
                global.utils.register_for_sampling(entity)
            end
            local s = global.energy_samples[uid]
            local egen = entity.energy_generated_last_tick or 0
            if s and s["energy_generated_last_tick"] then
                local old = s["energy_generated_last_tick"][cursor] or 0
                s["energy_generated_last_tick"][cursor] = egen
                global.sample_running_sums[uid]["energy_generated_last_tick"] = (global.sample_running_sums[uid]["energy_generated_last_tick"] or 0) - old + egen
            end
            -- Accumulate per-network production for actual_power pass.
            local nid = entity.electric_network_id
            if nid then
                net_production[nid] = (net_production[nid] or 0) + egen
            end
            update_is_working(entity, uid, cursor)
        end
    end

    -- Sample solar panels
    for uid, entity in pairs(global.tracked_entities.solar) do
        if entity.valid then
            if not global.energy_samples[uid] then
                global.utils.register_for_sampling(entity)
            end
            local s = global.energy_samples[uid]
            local val = entity.electric_output_flow_limit or 0
            -- Factorio may return math.huge OR DBL_MAX (~1.798e+308) when
            -- the network doesn't constrain the panel.  Clamp to rated max.
            if is_huge(val) then
                val = get_solar_max_production(entity)
            end
            if s and s["electric_output_flow_limit"] then
                local old = s["electric_output_flow_limit"][cursor] or 0
                if is_huge(old) then
                    old = 0
                end
                s["electric_output_flow_limit"][cursor] = val
                local sum = (global.sample_running_sums[uid]["electric_output_flow_limit"] or 0) - old + val
                if is_huge(sum) then
                    sum = val * WINDOW_SIZE
                end
                global.sample_running_sums[uid]["electric_output_flow_limit"] = sum
            end
            -- Accumulate per-network production for actual_power pass.
            local nid = entity.electric_network_id
            if nid then
                net_production[nid] = (net_production[nid] or 0) + val
            end
            update_is_working(entity, uid, cursor)
        end
    end

    -- Sample inserters: detect held_stack transitions (item held → empty = completed transfer)
    for uid, entity in pairs(global.tracked_entities.inserter) do
        if entity.valid then
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
    for uid, entity in pairs(global.tracked_entities.drill) do
        if entity.valid then
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
    for uid, entity in pairs(global.tracked_entities.pipe) do
        if entity.valid and entity.fluidbox and #entity.fluidbox > 0 then
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
    for uid, entity in pairs(global.tracked_entities.crafting) do
        if entity.valid then
            if not global.energy_samples[uid] then
                global.utils.register_for_sampling(entity)
            end
            update_is_working(entity, uid, cursor)
        end
    end

    -- Fluid-processing buildings: assembling-machine (oil-refinery,
    -- chemical-plant), mining-drill (pumpjack), boiler, generator, etc.
    for uid, entity in pairs(global.tracked_entities.fluid) do
        if entity.valid and entity.fluidbox and #entity.fluidbox > 0 then
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

    -- -----------------------------------------------------------------------
    -- Electricity actual_power pass: compute per-tick actual power for each
    -- electric consumer using the same formula the agent observes:
    --   actual_power = (drain + (max - drain) × is_working) × satisfaction
    -- where satisfaction = min(total_production / total_demand, 1).
    -- We group by electric_network_id to handle multiple independent grids.
    --
    -- net_production was already filled in-place during the generator and
    -- solar loops above (no extra find_entities_filtered scans needed here).
    -- -----------------------------------------------------------------------
    -- Collect per-consumer demand this tick
    local net_demand = {}      -- network_id → total J/tick demanded this tick
    local consumer_tick_data = {} -- list of {uid, net_id, requested}

    -- Compute each consumer's requested power this tick and sum per-network demand
    for uid, pd in pairs(global.sample_prototype_data) do
        if pd.max_energy_usage > 0 then
            local s = global.energy_samples[uid]
            if s and s["actual_power"] then
                -- Get this tick's is_working value (just written above)
                local iw = 0
                if s["is_working"] then
                    iw = s["is_working"][cursor] or 0
                end
                local requested = pd.drain + (pd.max_energy_usage - pd.drain) * iw
                -- Find network id from sampled_entities
                -- We stored it during registration or can look up now
                local nid = global.sample_network_id[uid]
                if nid then
                    net_demand[nid] = (net_demand[nid] or 0) + requested
                    consumer_tick_data[#consumer_tick_data + 1] = {
                        uid = uid, nid = nid, requested = requested,
                    }
                end
            end
        end
    end

    -- Compute satisfaction per network and write actual_power to ring buffer
    for _, cd in ipairs(consumer_tick_data) do
        local production = net_production[cd.nid] or 0
        local demand = net_demand[cd.nid] or 0
        local satisfaction = 1.0
        if demand > 0 then
            satisfaction = math.min(production / demand, 1.0)
        end
        local actual = cd.requested * satisfaction
        local s = global.energy_samples[cd.uid]
        if s and s["actual_power"] then
            local old = s["actual_power"][cursor] or 0
            s["actual_power"][cursor] = actual
            global.sample_running_sums[cd.uid]["actual_power"] =
                (global.sample_running_sums[cd.uid]["actual_power"] or 0) - old + actual
        end
    end

    -- -----------------------------------------------------------------------
    -- Global production flow tracking (force-level item + fluid statistics)
    -- -----------------------------------------------------------------------
    -- Reads the cumulative production/consumption counters from
    -- game.forces.player.item_production_statistics and
    -- game.forces.player.fluid_production_statistics, computes per-tick
    -- deltas, and feeds them into the same ring-buffer / running-sum scheme
    -- used for entity-level sampling.
    local force = game.forces.player
    local stats_sources = {
        force.item_production_statistics,
        force.fluid_production_statistics,
    }
    for _, stats in ipairs(stats_sources) do
        -- Factorio naming: input_counts = items produced (input to the tracker),
        --                  output_counts = items consumed (output from the tracker).
        local mappings = {
            { dir = "produced", counts = stats.input_counts },
            { dir = "consumed", counts = stats.output_counts },
        }
        for _, m in ipairs(mappings) do
            local dir = m.dir
            for name, cumulative in pairs(m.counts) do
                -- First time seeing this item: seed prev to current so delta=0
                -- (avoids injecting the entire cumulative history as a spike)
                local prev = global.production_flow_prev[dir][name] or cumulative
                local delta = cumulative - prev
                global.production_flow_prev[dir][name] = cumulative

                -- Ensure ring buffer and running sum exist for this item/fluid
                if not global.production_flow_ring[name] then
                    global.production_flow_ring[name] = { produced = {}, consumed = {} }
                    global.production_flow_sums[name] = { produced = 0, consumed = 0 }
                end

                local old = global.production_flow_ring[name][dir][cursor] or 0
                global.production_flow_ring[name][dir][cursor] = delta
                global.production_flow_sums[name][dir] = (global.production_flow_sums[name][dir] or 0) - old + delta
            end
        end
    end
end)
