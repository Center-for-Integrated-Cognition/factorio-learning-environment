global.actions.add_to_inventory = function(player_index, item_names_and_counts_json)
    local player = global.agent_characters[player_index]
    local item_names_and_counts = game.json_to_table(item_names_and_counts_json) or {}
    -- Avoid logging raw tables; convert toN for readability and safety
	
    local function get_player_inventory_items(player)
       local inventory = player.get_main_inventory()
       if not inventory or not inventory.valid then
           return nil
       end

       local item_counts = inventory.get_contents()
       return item_counts
    end

    -- Loop through the entity names and insert them into the player's inventory
    for item, count in pairs(item_names_and_counts) do
        player.get_main_inventory().insert{name=item, count=count}
    end

    local inventory_items = player.get_main_inventory().get_contents()
	return dump(inventory_items)
end
