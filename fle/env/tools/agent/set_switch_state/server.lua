global.actions.set_switch_state = function(player_index, x, y, enabled)
    local player = global.agent_characters[player_index]
    local surface = player.surface

    local entities = surface.find_entities_filtered{
        position = {x, y},
        radius = 0.5,
        name = "constant-combinator"
    }

    if #entities == 0 then
        error("No constant-combinator found at position (" .. x .. ", " .. y .. ")")
    end

    local combinator = entities[1]
    local behavior = combinator.get_or_create_control_behavior()
    behavior.enabled = enabled

    -- Add (or overwrite) the green virtual signal at slot 1 with count 1
    local green_signal = {type = "virtual", name = "signal-green"}
    local params = behavior.parameters or {}

    -- Find existing slot for green signal, or use the next free slot
    local target_index = 1
    for _, param in ipairs(params) do
        if param.signal and param.signal.type == green_signal.type and param.signal.name == green_signal.name then
            target_index = param.index
            break
        end
    end

    behavior.set_signal(target_index, {signal = green_signal, count = 1})

    return global.utils.serialize_entity(combinator)
end
