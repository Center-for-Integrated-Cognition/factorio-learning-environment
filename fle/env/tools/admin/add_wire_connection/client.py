from typing import Literal, Union, Tuple

from fle.env.entities import EntityReference, WireType
from fle.env.tools import Tool

class AddWireConnection(Tool):
    def __init__(self, *args):
        super().__init__(*args)

    def __call__(
        self,
        entity1: EntityReference,
        entity1_side: str,
        entity2: EntityReference,
        entity2_side: str,
        wire: WireType = WireType.COPPER
    ) -> bool:
        """
        Connect two entities with a wire.

        :param entity1: First entity
        :param entity1_side: only needed in certain cases, 
                             one of 'left'/'right' (power-switches) or 'input'/'output' (combinators)
        :param entity2: Second entity
        :param entity2_side: only needed in certain cases,
                             one of 'left'/'right' (power-switches) or 'input'/'output' (combinators)
        :param wire: WireType enum, either "copper", "red", or "green".
        :return: True if the connection was made successfully.
        :raises Exception: If entities cannot be found or connected.
        """

        response, info = self.execute(self.player_index, entity1.to_dict(), entity1_side, entity2.to_dict(), entity2_side, str(wire))
        if response == 1:
            return True

        if isinstance(info, str) and "error:" in info:
            print("Error in add_wire_connection: ", info.split("error:")[1])
        else:
            print(response)
        return False
