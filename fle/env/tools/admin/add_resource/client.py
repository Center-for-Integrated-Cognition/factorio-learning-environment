from typing import Literal, Union, Tuple

from fle.env.entities import EntityReference, WireType, Position
from fle.env.tools import Tool

class AddResource(Tool):
    def __init__(self, *args):
        super().__init__(*args)

    def __call__(
        self,
        name: str,
        position: Position,
        amount: int,
    ) -> bool:
        """
        Adds a resource to the map surface

        :param name: prototype name of the resource
        :param position: the position to add the resource
        :param amount: amount to add
        :return: True if the resource was added successfully.
        """

        response, info = self.execute(self.player_index, name, [position.x, position.y], amount)
        if response == 1:
            return True

        if isinstance(info, str) and "error:" in info:
            print("Error in add_resource: ", info.split("error:")[1])
        else:
            print("Error in add_resource: ", response)
        return False
