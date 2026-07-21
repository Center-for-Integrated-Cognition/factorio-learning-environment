global.actions.set_control_behavior = function(player_index, entity_ref, behavior_info)
    local surface = global.agent_characters[player_index].surface

    -- Find the given entity 
    local entity = surface.find_entity(entity_ref.name, entity_ref.position)

    if not entity then
        return "error: no " .. entity_ref.name .. " entity found at position (" .. entity_ref.position[1] .. ", " .. entity_ref.position[2] .. ")"
    end

    local behavior = entity.get_or_create_control_behavior()
    if behavior == nil then
        return "error: entity '" .. entity.name .. "' does not support a control behavior"
    end

    local function create_condition(condition_info)
        return {
            comparator = ">",
            first_signal = { type = "virtual", name = "signal-C" },
            constant = 50
        }
    end

    -- Behavior for power switch
    if entity_ref.name == "power-switch" then
        behavior.circuit_condition = {
            condition = behavior_info
        }
    end

    if entity_ref.name == "accumulator" then
        behavior.output_signal = behavior_info
    end

    return 1
end
