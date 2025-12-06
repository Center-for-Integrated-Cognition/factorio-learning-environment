from fle.env.tools import Tool
from typing import Dict, Any
import json


class AddToInventory(Tool):
    def __init__(self, connection, game_state):
        super().__init__(connection, game_state)

    def __call__(self, inventory: Dict[str, Any]) -> bool:
        """
        Adds items to the inventory for an agent character
        """
        inventory_json = json.dumps(inventory)
        response, elapsed = self.execute(self.player_index, inventory_json)
        return True
