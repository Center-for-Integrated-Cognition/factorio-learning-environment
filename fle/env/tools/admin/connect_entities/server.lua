global.actions.connect_entities = function(player_index, entity1_ref, entity1_side, entity2_ref, entity2_side, wire_name)
    local surface = global.agent_characters[player_index].surface

    -- Find entities near each position
    local entity1 = surface.find_entity(entity1_ref.name, entity1_ref.position)
    local entity2 = surface.find_entity(entity2_ref.name, entity2_ref.position)

    if not entity1 then
        return "error: no " .. entity1_ref.name .. " entity found at position (" .. entity1_ref.position[0] .. ", " .. entity1_ref.position[1] .. ")"
    end
    if not entity2 then 
        return "error: no " .. entity2_ref.name .. " entity found at position (" .. entity2_ref.position[0] .. ", " .. entity2_ref.position[1] .. ")"
    end

    -- Resolve wire type
    local wire_type
    if wire_name == "copper" then
        wire_type = defines.wire_type.copper
    elseif wire_name == "red" then
        wire_type = defines.wire_type.red
    elseif wire_name == "green" then
        wire_type = defines.wire_type.green
    else
        return "error: invalid wire type '" .. tostring(wire_name) .. "', must be 'red' or 'green'"
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
