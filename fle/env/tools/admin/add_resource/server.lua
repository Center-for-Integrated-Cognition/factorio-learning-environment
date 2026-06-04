global.actions.add_resource = function(player_index, name, pos, amount)
    local surface = global.agent_characters[player_index].surface

	local existing = surface.find_entity(name, pos)
	if existing then
        existing.amount = amount
	else
		local res = surface.create_entity{name=name, position=pos, amount=amount}
		if not res then
			return "error: could not create resource " .. name .. " at (" .. pos[1] .. ", " .. pos[2] .. ")"
		end
	end

	--- Make sure mining drills are updated with patch info
    for _, e in pairs(surface.find_entities_filtered{type="mining-drill", position=pos, radius=5 }) do
        e.update_connections()
    end
end
