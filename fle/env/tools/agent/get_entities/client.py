from time import sleep
from typing import List, Set, Union

from fle.env.entities import Position, Entity, EntityGroup, PipeGroup, Pipe
from fle.env.game_types import Prototype
from fle.env.tools.agent.connect_entities.groupable_entities import (
    agglomerate_groupable_entities,
)
from fle.env.tools import Tool


class GetEntities(Tool):
    def __init__(self, connection, game_state):
        super().__init__(connection, game_state)

    def __call__(
        self,
        entities: Union[Set[Prototype], Prototype] = set(),
        position: Position = None,
        radius: float = 1000,
    ) -> List[Union[Entity, EntityGroup]]:
        """
        Get entities within a radius of a given position.
        :param entities: Set of entity prototypes to filter by. If empty, all entities are returned.
        :param position: Position to search around. Can be a Position object or "player" for player's position.
        :param radius: Radius to search within.
        :param player_only: If True, only player entities are returned, otherwise terrain features too.
        :return: Found entities
        """

        try:
            if not isinstance(position, Position) and position is not None:
                raise ValueError("The second argument must be a Position object")

            if not isinstance(entities, Set):
                entities = set([entities])

            # Handle group prototypes by expanding them to their component types
            expanded_entities = set()
            # internal_entities are fetched from Lua and used for grouping,
            # but filtered out of the final result (only groups pass through)
            internal_entities = set()
            group_requests = set()

            for entity in entities:
                if entity == Prototype.BeltGroup:
                    # For belt groups, search for all belt types and group them
                    belt_types = {
                        Prototype.TransportBelt,
                        Prototype.FastTransportBelt,
                        Prototype.ExpressTransportBelt,
                        Prototype.UndergroundBelt,
                        Prototype.FastUndergroundBelt,
                        Prototype.ExpressUndergroundBelt,
                    }
                    expanded_entities.update(belt_types)
                    group_requests.add(Prototype.BeltGroup)
                elif entity == Prototype.PipeGroup:
                    # For pipe groups, search for pipe types and group them
                    pipe_types = {Prototype.Pipe, Prototype.UndergroundPipe}
                    expanded_entities.update(pipe_types)
                    # Also fetch all fluid handler types so they can be
                    # grouped into PipeGroups (direct connections without pipes)
                    fluid_handler_types = {
                        Prototype.Boiler,
                        Prototype.SteamEngine,
                        Prototype.OffshorePump,
                        Prototype.Pump,
                        Prototype.PumpJack,
                        Prototype.OilRefinery,
                        Prototype.ChemicalPlant,
                        Prototype.StorageTank,
                        Prototype.AssemblingMachine2,
                        Prototype.AssemblingMachine3,
                    }
                    internal_entities.update(fluid_handler_types)
                    group_requests.add(Prototype.PipeGroup)
                elif entity == Prototype.ElectricityGroup:
                    # For electricity groups, search for pole types and group them
                    pole_types = {
                        Prototype.SmallElectricPole,
                        Prototype.MediumElectricPole,
                        Prototype.BigElectricPole,
                    }
                    expanded_entities.update(pole_types)
                    group_requests.add(Prototype.ElectricityGroup)
                else:
                    expanded_entities.add(entity)

            # Use expanded + internal entities for the Lua query
            query_entities = expanded_entities | internal_entities

            # Serialize entity_names as a string
            entity_names = (
                "["
                + ",".join([f'"{entity.value[0]}"' for entity in query_entities])
                + "]"
                if query_entities
                else "[]"
            )

            # We need to add a small 50ms sleep to ensure that the entities have updated after previous actions
            sleep(0.05)

            if position is None:
                response, time_elapsed = self.execute(
                    self.player_index, radius, entity_names
                )
            else:
                response, time_elapsed = self.execute(
                    self.player_index, radius, entity_names, position.x, position.y
                )

            if not response:
                return []

            if (not isinstance(response, dict) and not response) or isinstance(
                response, str
            ):  # or (isinstance(response, dict) and not response):
                raise Exception("Could not get entities", response)

            entities_list = []
            for raw_entity_data in response:
                if isinstance(raw_entity_data, list):
                    continue

                entity_data = self.clean_response(raw_entity_data)
                # Find the matching Prototype
                matching_prototype = None
                for prototype in Prototype:
                    if prototype.value[0] == entity_data["name"].replace("_", "-"):
                        matching_prototype = prototype
                        break

                if matching_prototype is None:
                    print(
                        f"Warning: No matching Prototype found for {entity_data['name']}"
                    )
                    continue

                # Apply standard filtering - check against expanded and internal entities too
                if (
                    entities
                    and matching_prototype not in entities
                    and matching_prototype not in expanded_entities
                    and matching_prototype not in internal_entities
                ):
                    continue

                metaclass = matching_prototype.value[1]
                while isinstance(metaclass, tuple):
                    metaclass = metaclass[1]

                # Process nested dictionaries (like inventories)
                for key, value in entity_data.items():
                    if isinstance(value, dict):
                        entity_data[key] = self.process_nested_dict(value)

                entity_data["prototype"] = matching_prototype

                # remove all empty values from the entity_data dictionary
                entity_data = {
                    k: v for k, v in entity_data.items() if v or isinstance(v, int)
                }

                try:
                    if "inventory" in entity_data:
                        if isinstance(entity_data["inventory"], list):
                            for inv in entity_data["inventory"]:
                                entity_data["inventory"] += inv
                        else:
                            inventory_data = {
                                k: v
                                for k, v in entity_data["inventory"].items()
                                if v or isinstance(v, int)
                            }
                            entity_data["inventory"] = inventory_data

                    entity = metaclass(**entity_data)
                    entities_list.append(entity)
                except Exception as e1:
                    print(f"Could not create {entity_data['name']} object: {e1}")

            # Group entities when:
            # 1. User explicitly requests group types, OR
            # 2. User provides a position filter (suggesting they want nearby entities grouped), OR
            # 3. No specific entities requested (get all entities - should be grouped), OR
            # 4. User requests individual pole entities (restore original behavior - poles are always grouped)
            pole_types = {
                Prototype.SmallElectricPole,
                Prototype.MediumElectricPole,
                Prototype.BigElectricPole,
            }
            should_group = (
                not entities  # No filter = group everything
                or any(
                    proto
                    in {
                        Prototype.ElectricityGroup,
                        Prototype.PipeGroup,
                        Prototype.BeltGroup,
                    }
                    for proto in entities
                )  # Explicit group request
                or (
                    entities and position is not None
                )  # Individual entities with position filter = group for convenience
            )

            if should_group:
                # Collect all pipes
                pipes = [
                    entity
                    for entity in entities_list
                    if hasattr(entity, "prototype")
                    and entity.prototype in (Prototype.Pipe, Prototype.UndergroundPipe)
                ]

                # Collect fluid handlers (non-pipe entities with a fluidbox_id)
                fluid_handlers = [
                    entity
                    for entity in entities_list
                    if hasattr(entity, "fluidbox_id")
                    and entity.fluidbox_id != 0
                    and not isinstance(entity, Pipe)
                ]

                # Build a unified dict: {fluidbox_id: {pipes: [...], handlers: [...]}}
                fluid_systems = {}
                for pipe in pipes:
                    fid = pipe.fluidbox_id
                    if fid not in fluid_systems:
                        fluid_systems[fid] = {"pipes": [], "handlers": []}
                    fluid_systems[fid]["pipes"].append(pipe)

                for handler in fluid_handlers:
                    # Handlers may participate in multiple fluid systems
                    handler_ids = getattr(handler, "fluidbox_ids", []) or []
                    if not handler_ids:
                        handler_ids = [handler.fluidbox_id]
                    for fid in handler_ids:
                        if fid == 0:
                            continue
                        if fid not in fluid_systems:
                            fluid_systems[fid] = {"pipes": [], "handlers": []}
                        fluid_systems[fid]["handlers"].append(handler)

                # Build PipeGroups from the unified dict
                if fluid_systems:
                    # Remove pipes from main list (they are absorbed into groups)
                    for pipe in pipes:
                        entities_list.remove(pipe)
                    # Do NOT remove fluid handlers — they stay as individual entities too

                    from fle.env.entities import EntityStatus
                    from statistics import mean

                    for fid, members in fluid_systems.items():
                        group_pipes = members["pipes"]
                        group_handlers = members["handlers"]

                        # Determine status from pipes if present, else from handlers
                        if group_pipes:
                            if any(p.contents > 0 and p.flow_rate > 0 for p in group_pipes):
                                status = EntityStatus.WORKING
                            elif all(p.contents == 0 for p in group_pipes):
                                status = EntityStatus.EMPTY
                            elif all(p.flow_rate == 0 for p in group_pipes):
                                status = EntityStatus.FULL_OUTPUT
                            else:
                                status = EntityStatus.NORMAL
                            pos = group_pipes[0].position
                        else:
                            # Handler-only group (direct connections, no pipes)
                            status = EntityStatus.WORKING
                            pos = group_handlers[0].position

                        entities_list.append(PipeGroup(
                            id=fid,
                            pipes=group_pipes,
                            fluid_handlers=group_handlers,
                            status=status,
                            position=pos,
                        ))

                # Second pass: group directly-connected fluid handlers
                # that have no fluid system ID (direct connections, no pipes)
                ungrouped_handlers = [
                    entity
                    for entity in entities_list
                    if hasattr(entity, "fluidbox_neighbours")
                    and entity.fluidbox_neighbours
                    and getattr(entity, "fluidbox_id", 0) == 0
                    and not isinstance(entity, Pipe)
                ]

                if ungrouped_handlers:
                    # Build lookup: entity id -> entity object
                    id_to_entity = {e.id: e for e in ungrouped_handlers}

                    # Ensure EntityStatus is imported (may not be if no pipe groups existed)
                    from fle.env.entities import EntityStatus as ES

                    # Union-Find to discover connected components
                    parent = {e.id: e.id for e in ungrouped_handlers}

                    def find(x):
                        while parent[x] != x:
                            parent[x] = parent[parent[x]]
                            x = parent[x]
                        return x

                    def union(a, b):
                        ra, rb = find(a), find(b)
                        if ra != rb:
                            parent[ra] = rb

                    for handler in ungrouped_handlers:
                        for neighbour_id in handler.fluidbox_neighbours:
                            if neighbour_id in id_to_entity:
                                union(handler.id, neighbour_id)

                    # Collect components
                    components = {}
                    for handler in ungrouped_handlers:
                        root = find(handler.id)
                        if root not in components:
                            components[root] = []
                        components[root].append(handler)

                    # Create PipeGroups with synthetic negative IDs
                    synthetic_id = -1
                    for root, members in components.items():
                        entities_list.append(PipeGroup(
                            id=synthetic_id,
                            pipes=[],
                            fluid_handlers=members,
                            status=ES.WORKING,
                            position=members[0].position,
                        ))
                        synthetic_id -= 1

                poles = [
                    entity
                    for entity in entities_list
                    if hasattr(entity, "prototype")
                    and entity.prototype
                    in (
                        Prototype.SmallElectricPole,
                        Prototype.BigElectricPole,
                        Prototype.MediumElectricPole,
                    )
                ]
                group = agglomerate_groupable_entities(poles)
                [entities_list.remove(pole) for pole in poles]
                entities_list.extend(group)

                walls = [
                    entity
                    for entity in entities_list
                    if hasattr(entity, "prototype")
                    and entity.prototype == Prototype.StoneWall
                ]
                group = agglomerate_groupable_entities(walls)
                [entities_list.remove(wall) for wall in walls]
                entities_list.extend(group)

                belt_types = (
                    Prototype.TransportBelt,
                    Prototype.FastTransportBelt,
                    Prototype.ExpressTransportBelt,
                    Prototype.UndergroundBelt,
                    Prototype.FastUndergroundBelt,
                    Prototype.ExpressUndergroundBelt,
                )
                belts = [
                    entity
                    for entity in entities_list
                    if hasattr(entity, "prototype") and entity.prototype in belt_types
                ]
                group = agglomerate_groupable_entities(belts)
                [entities_list.remove(belt) for belt in belts]
                entities_list.extend(group)

            # Final filtering after grouping is complete
            if entities:
                filtered_entities = []
                for entity in entities_list:
                    # Check entity prototype or group type
                    # Note: internal_entities are deliberately excluded here —
                    # they were only fetched for grouping, not for direct return
                    if hasattr(entity, "prototype") and (
                        entity.prototype in entities
                        or entity.prototype in expanded_entities
                    ):
                        filtered_entities.append(entity)
                    elif hasattr(entity, "__class__"):
                        # Handle group entities
                        if entity.__class__.__name__ == "ElectricityGroup":
                            pole_types = {
                                Prototype.SmallElectricPole,
                                Prototype.MediumElectricPole,
                                Prototype.BigElectricPole,
                            }
                            if Prototype.ElectricityGroup in group_requests:
                                # Explicit group request - return the group
                                filtered_entities.append(entity)
                            elif (
                                any(pole_type in entities for pole_type in pole_types)
                                and position is not None
                            ):
                                # Individual poles requested with position - return group for convenience
                                filtered_entities.append(entity)
                            elif any(pole_type in entities for pole_type in pole_types):
                                # Individual poles requested - return group (restores original behavior)
                                # Power poles are inherently networked, so groups are more useful than individuals
                                filtered_entities.append(entity)
                        elif entity.__class__.__name__ == "PipeGroup":
                            pipe_types = {Prototype.Pipe, Prototype.UndergroundPipe}
                            if Prototype.PipeGroup in group_requests:
                                # Explicit group request - return the group
                                filtered_entities.append(entity)
                            elif (
                                any(pipe_type in entities for pipe_type in pipe_types)
                                and position is not None
                            ):
                                # Individual pipes requested with position - return group for convenience
                                filtered_entities.append(entity)
                            elif any(pipe_type in entities for pipe_type in pipe_types):
                                # Individual pipes requested - return group (restores original behavior)
                                # Pipes are inherently networked, so groups are more useful than individuals
                                filtered_entities.append(entity)
                        elif entity.__class__.__name__ == "BeltGroup":
                            belt_types = {
                                Prototype.TransportBelt,
                                Prototype.FastTransportBelt,
                                Prototype.ExpressTransportBelt,
                                Prototype.UndergroundBelt,
                                Prototype.FastUndergroundBelt,
                                Prototype.ExpressUndergroundBelt,
                            }
                            if Prototype.BeltGroup in group_requests:
                                # Explicit group request - return the group
                                filtered_entities.append(entity)
                            elif (
                                any(belt_type in entities for belt_type in belt_types)
                                and position is not None
                            ):
                                # Individual belts requested with position - return group for convenience
                                filtered_entities.append(entity)
                            elif (
                                any(belt_type in entities for belt_type in belt_types)
                                and position is None
                            ):
                                # Individual belts requested without position - extract individual belts from group
                                for belt in entity.belts:
                                    if (
                                        hasattr(belt, "prototype")
                                        and belt.prototype in entities
                                    ):
                                        filtered_entities.append(belt)
                        elif entity.__class__.__name__ == "WallGroup":
                            # WallGroup doesn't have a corresponding Prototype, but include if present
                            filtered_entities.append(entity)
                entities_list = filtered_entities

            return entities_list

        except Exception as e:
            raise Exception(f"Error in GetEntities: {e}")

    def process_nested_dict(self, nested_dict):
        """Helper method to process nested dictionaries"""
        if isinstance(nested_dict, dict):
            if all(isinstance(key, int) for key in nested_dict.keys()):
                return [
                    self.process_nested_dict(value) for value in nested_dict.values()
                ]
            else:
                return {
                    key: self.process_nested_dict(value)
                    for key, value in nested_dict.items()
                }
        return nested_dict
