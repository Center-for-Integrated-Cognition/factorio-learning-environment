from typing import Literal, Union, Tuple

from fle.env.entities import EntityReference, WireType
from fle.env.tools import Tool

class SetControlBehavior(Tool):
    def __init__(self, *args):
        super().__init__(*args)

    def __call__(
        self,
        entity: EntityReference,
        behavior_info: dict,
    ) -> bool:
        """
        Sets the control behavior on a given entity

        :param entity: First entity
        :param behavior_info
        :return: True if the connection was made successfully.
        :raises Exception: If entities cannot be found or connected.
        """

        print("SETTING CONTROL BEHAVIOR")
        print(entity)
        print(behavior_info)
        response, info = self.execute(self.player_index, entity.to_dict(), behavior_info)

        if response == 1:
            return True

        if isinstance(info, str) and "error:" in info:
            print("Error in set_control_behavior: ", info.split("error:")[1])
        else:
            print(response)
            print(info)
        return False
