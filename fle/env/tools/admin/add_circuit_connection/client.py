from typing import Literal, Union, Tuple

from fle.env.entities import Position, Entity, WireColor
from fle.env.tools import Tool


class AddCircuitConnection(Tool):
    def __init__(self, *args):
        super().__init__(*args)

    def __call__(
        self,
        entity1: Union[Entity, Position, Tuple[float, float]],
        entity2: Union[Entity, Position, Tuple[float, float]],
        wire: WireColor = WireColor.RED,
    ) -> bool:
        """
        Connect two entities with a circuit wire.

        :param entity1: First entity or its position.
        :param entity2: Second entity or its position.
        :param wire: WireColor enum, either "red" or "green".
        :return: True if the connection was made successfully.
        :raises Exception: If entities cannot be found or connected.
        """
        x1, y1 = self.get_position(entity1)
        x2, y2 = self.get_position(entity2)
        response, _ = self.execute(self.player_index, x1, y1, x2, y2, str(wire))

        #print(f"ADD {wire} wire from ({x1}, {y1}) and ({x2}, {y2})")

        if isinstance(response, str) and response.startswith("error"):
            raise Exception(response)

        #print(response)

        return True
