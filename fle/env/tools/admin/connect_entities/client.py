from typing import Literal, Union, Tuple

from fle.env.entities import EntityReference, WireType
from fle.env.tools import Tool


class ConnectEntities(Tool):
    def __init__(self, *args):
        super().__init__(*args)

    def __call__(
        self,
        entity1: EntityReference,
        entity2: EntityReference,
        wire: WireType = WireType.COPPER
    ) -> bool:
        """
        Connect two entities with a circuit wire.

        :param entity1: First entity
        :param entity2: Second entity
        :param wire: WireType enum, either "copper", "red", or "green".
        :return: True if the connection was made successfully.
        :raises Exception: If entities cannot be found or connected.
        """
        response, info = self.execute(self.player_index, entity1.to_dict(), entity2.to_dict(), str(wire))
        print(response)
        print(info)
        

        if isinstance(response, str) and response.startswith("error"):
            print("Error in connect_entities: ", response)
            return False

        return True
