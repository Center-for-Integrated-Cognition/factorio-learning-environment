from typing import Union, Tuple

from fle.env.entities import Entity, Position
from fle.env.tools import Tool


class AddEnabledCircuitCondition(Tool):
    def __init__(self, *args):
        super().__init__(*args)

    def __call__(
        self,
        entity: Union[Entity, Position, Tuple[float, float]],
    ) -> bool:
        """
        Add a GenericOnOffControlBehavior circuit condition to an entity that enables
        it when the green virtual signal is not equal to zero.

        :param entity: The entity or its position to apply the condition to.
        :return: True if the condition was applied successfully.
        :raises Exception: If no entity is found at the position or it does not
                           support a control behavior.
        """
        x, y = self.get_position(entity)

        response, _ = self.execute(self.player_index, x, y)

        if isinstance(response, str) and response.startswith("error"):
            raise Exception(response)

        return True
