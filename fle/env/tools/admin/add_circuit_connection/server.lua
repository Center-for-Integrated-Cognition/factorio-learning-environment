global.actions.add_circuit_connection = function(player_index, x1, y1, x2, y2, wire_color)
    local surface = global.agent_characters[player_index].surface

    -- Find entities near each position
    local entities1 = surface.find_entities_filtered{position = {x1, y1}, radius = 0.5}
    local entities2 = surface.find_entities_filtered{position = {x2, y2}, radius = 0.5}

    if #entities1 == 0 then
        return "error: no entity found at position (" .. x1 .. ", " .. y1 .. ")"
    end
    if #entities2 == 0 then
        return "error: no entity found at position (" .. x2 .. ", " .. y2 .. ")"
    end

    local entity1 = entities1[1]
    local entity2 = entities2[1]

    -- Resolve wire type
    local wire_type
    if wire_color == "red" then
        wire_type = defines.wire_type.red
    elseif wire_color == "green" then
        wire_type = defines.wire_type.green
    else
        return "error: invalid wire color '" .. tostring(wire_color) .. "', must be 'red' or 'green'"
    end

    local success = entity1.connect_neighbour{
        wire = wire_type,
        target_entity = entity2,
    }

    if success then
        return 1
    else
        return "error: could not connect " .. entity1.name .. " to " .. entity2.name .. " (entities may not support circuit connections)"
    end
end
