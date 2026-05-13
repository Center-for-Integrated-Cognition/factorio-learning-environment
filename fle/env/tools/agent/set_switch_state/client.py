from typing import Union, Tuple

from fle.env.entities import Entity, Position
from fle.env.game_types import prototype_by_name
from fle.env.tools import Tool


class SetSwitchState(Tool):
    def __init__(self, connection, game_state):
        super().__init__(connection, game_state)

    def __call__(
        self,
        entity: Union[Entity, Position, Tuple[float, float]],
        enabled: bool,
    ) -> Entity:
        """
        Enable or disable the output of a constant combinator.

        :param entity: The constant combinator entity or its position.
        :param enabled: True to turn the combinator on, False to turn it off.
        :return: The updated entity.
        :raises Exception: If no constant combinator is found at the position.
        """
        x, y = self.get_position(entity)

        response, _ = self.execute(self.player_index, x, y, enabled)

        if isinstance(response, str) and response.startswith("error"):
            raise Exception(response)

        cleaned = self.clean_response(response)

        if "prototype" not in cleaned:
            name = cleaned.get("name", "constant-combinator")
            cleaned["prototype"] = prototype_by_name.get(name)

        metaclass = entity.__class__ if isinstance(entity, Entity) else Entity
        return metaclass(**cleaned)
