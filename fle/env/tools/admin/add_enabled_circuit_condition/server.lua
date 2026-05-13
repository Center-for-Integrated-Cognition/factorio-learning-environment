global.actions.add_enabled_circuit_condition = function(player_index, x, y)
    local surface = global.agent_characters[player_index].surface

    local entities = surface.find_entities_filtered{position = {x, y}, radius = 0.5}

    if #entities == 0 then
        return "error: no entity found at position (" .. x .. ", " .. y .. ")"
    end

    local entity = entities[1]
    local behavior = entity.get_or_create_control_behavior()

    if behavior == nil then
        return "error: entity '" .. entity.name .. "' does not support a control behavior"
    end



    -- Enable circuit-based enable/disable control
    -- behavior.use_colors = false
    behavior.circuit_mode_of_operation = defines.control_behavior.inserter.circuit_mode_of_operation.enable_disable

    -- Set condition: green signal ≠ 0
    behavior.circuit_condition = {
        condition = {
            comparator = "!=",
            first_signal = {type = "virtual", name = "signal-green"},
            constant = 0
        }
    }

    return 1
end
