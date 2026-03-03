global.actions.get_entities = function(player_index, radius, entity_names_json, position_x, position_y)
    local player = global.agent_characters[player_index]
    local position
    if position_x and position_y then
        position = {x = tonumber(position_x), y = tonumber(position_y)}
    else
        position = player.position
    end

    radius = tonumber(radius) or 5
    local entity_names = game.json_to_table(entity_names_json) or {}
    local area = {
        {position.x - radius, position.y - radius},
        {position.x + radius, position.y + radius}
    }

    local filter = {}
    if entity_names and #entity_names > 0 then
        filter = {name = entity_names}
    end

    local entities

    if #entity_names > 0 then
        entities = player.surface.find_entities_filtered{area = area, force = player.force, filter=filter}
    else
        entities = player.surface.find_entities_filtered{area = area, force = player.force}
    end

    -- Rebuild belt group IDs if any belt types were requested (or all entities)
    local belt_type_set = {
        ["transport-belt"]=true, ["underground-belt"]=true, ["splitter"]=true,
        ["fast-transport-belt"]=true, ["fast-underground-belt"]=true, ["fast-splitter"]=true,
        ["express-transport-belt"]=true, ["express-underground-belt"]=true, ["express-splitter"]=true
    }
    local needs_belt_groups = (#entity_names == 0)  -- all entities requested
    if not needs_belt_groups then
        for _, name in ipairs(entity_names) do
            if belt_type_set[name] then
                needs_belt_groups = true
                break
            end
        end
    end
    if needs_belt_groups then
        global.utils.rebuild_belt_groups(player.surface)
    end

    local result = {}
    for _, entity in ipairs(entities) do
        if entity.name ~= 'character' then
            local serialized = global.utils.serialize_entity(entity)
            table.insert(result, serialized)
        end
    end
    return dump(result)
end