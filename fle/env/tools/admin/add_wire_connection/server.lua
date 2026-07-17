global.actions.add_wire_connection = function(player_index, entity1_ref, entity1_side, entity2_ref, entity2_side, wire_name)
    local surface = global.agent_characters[player_index].surface

    -- Find entities near each position
    local entity1 = surface.find_entity(entity1_ref.name, entity1_ref.position)
    local entity2 = surface.find_entity(entity2_ref.name, entity2_ref.position)

    if not entity1 then
        return "error: no " .. entity1_ref.name .. " entity found at position (" .. entity1_ref.position[1] .. ", " .. entity1_ref.position[2] .. ")"
    end
    if not entity2 then 
        return "error: no " .. entity2_ref.name .. " entity found at position (" .. entity2_ref.position[1] .. ", " .. entity2_ref.position[2] .. ")"
    end

    -- Build the wire connection definition
    local connection = {
        target_entity = entity2,
    }

    -- Resolve wire type
    local wire_type
    if wire_name == "copper" then
        connection.wire = defines.wire_type.copper
    elseif wire_name == "red" then
        connection.wire = defines.wire_type.red
    elseif wire_name == "green" then
        connection.wire = defines.wire_type.green
    else
        return "error: invalid wire type '" .. tostring(wire_name) .. "', must be 'copper', 'red', or 'green'"
    end

    -- Helper: returns the wire_connection_id for a power-switch ref, or nil if not applicable
    local function resolve_wire_id(entity_name, entity_side)
        if entity_name == "power-switch" and wire_name == "copper" then
            if entity_side == "left" then
                return defines.wire_connection_id.power_switch_left
            elseif entity_side == "right" then
                return defines.wire_connection_id.power_switch_right
            else
                return nil, "error: invalid side '" .. tostring(entity_side) .. "' for power-switch, must be 'left' or 'right'"
            end
        end
        return nil
    end

    -- Helper: returns the circuit_connection_id for a combinator ref, or nil if not applicable
    local function resolve_circuit_id(entity_name, entity_side)
        if entity_name == "arithmetic-combinator" or entity_name == "decider-combinator" then
            if entity_side == "input" then
                return defines.circuit_connector_id.combinator_input
            elseif entity_side == "output" then
                return defines.circuit_connector_id.combinator_output
            else
                return nil, "error: invalid side '" .. tostring(entity_side) .. "' for combinator, must be 'input' or 'output'"
            end
        end
        return nil
    end

    -- Resolve source_wire_id (power-switch on entity1)
    local source_wire_id, err = resolve_wire_id(entity1_ref.name, entity1_side)
    if err then return err end
    if source_wire_id then connection.source_wire_id = source_wire_id end

    -- Resolve target_wire_id (power-switch on entity2)
    local target_wire_id, err = resolve_wire_id(entity2_ref.name, entity2_side)
    if err then return err end
    if target_wire_id then connection.target_wire_id = target_wire_id end

    -- Resolve source_circuit_id (combinator on entity1)
    local source_circuit_id, err = resolve_circuit_id(entity1_ref.name, entity1_side)
    if err then return err end
    if source_circuit_id then connection.source_circuit_id = source_circuit_id end

    -- Resolve target_circuit_id (combinator on entity2)
    local target_circuit_id, err = resolve_circuit_id(entity2_ref.name, entity2_side)
    if err then return err end
    if target_circuit_id then connection.target_circuit_id = target_circuit_id end

    local success = entity1.connect_neighbour(connection)

    if success then
        return 1
    else
        return "error: could not connect " .. entity1.name .. " to " .. entity2.name .. " (entities may not support circuit connections)"
    end
end
