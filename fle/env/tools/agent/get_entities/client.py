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
                        Prototype.Substation,
                    }
                    expanded_entities.update(pole_types)
                    # Power switches are fetched so their switch_sides data can
                    # be used to merge electricity groups, but they are not
                    # returned as standalone entities.
                    internal_entities.add(Prototype.PowerSwitch)
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
                # Preserve int(0) and empty lists (e.g. resources: []) which
                # are falsy but semantically meaningful for Pydantic models.
                entity_data = {
                    k: v for k, v in entity_data.items()
                    if v or isinstance(v, (int, list))
                }

                try:
                    if "inventory" in entity_data:
                        if isinstance(entity_data["inventory"], list):
                            entity_data["inventory"] = [
                                self.process_nested_dict(inv)
                                if isinstance(inv, dict)
                                else inv
                                for inv in entity_data["inventory"]
                            ]
                        else:
                            inventory_data = {
                                k: v
                                for k, v in entity_data["inventory"].items()
                                if v or isinstance(v, (int, list))
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
                # that have fluidbox_neighbours but whose connections aren't
                # fully covered by existing fluid system groups.
                #
                # Key insight: Factorio's get_fluid_system_id() returns nil for
                # direct fluidbox-to-fluidbox connections (e.g. boiler steam
                # output → steam engine input with no pipe). So:
                #   - Boiler gets fluidbox_ids=[19] (water only; steam slot nil→skipped)
                #   - Steam engine gets fluidbox_id=0 (its steam slot is also nil)
                # The first pass only creates water groups. The steam connection
                # is invisible unless we use fluidbox_neighbours to discover it.

                # Collect ALL fluid handlers with neighbours (not just fluidbox_id==0)
                all_handlers_with_neighbours = [
                    entity
                    for entity in entities_list
                    if hasattr(entity, "fluidbox_neighbours")
                    and entity.fluidbox_neighbours
                    and not isinstance(entity, Pipe)
                    and not isinstance(entity, PipeGroup)
                ]

                if all_handlers_with_neighbours:
                    # Build co-membership index: for each existing PipeGroup,
                    # record which pairs of entity IDs are already grouped together.
                    # An edge (A↔B) is "covered" if A and B are both fluid_handlers
                    # in the same PipeGroup.
                    existing_group_members = []  # list of sets of entity IDs
                    for e in entities_list:
                        if isinstance(e, PipeGroup):
                            member_ids = frozenset(
                                h.id for h in getattr(e, 'fluid_handlers', [])
                            )
                            if member_ids:
                                existing_group_members.append(member_ids)

                    def edge_already_covered(id_a, id_b):
                        """True if id_a and id_b co-occur in some existing PipeGroup."""
                        for member_set in existing_group_members:
                            if id_a in member_set and id_b in member_set:
                                return True
                        return False

                    # Build lookup: entity id -> entity object
                    id_to_handler = {e.id: e for e in all_handlers_with_neighbours}

                    from fle.env.entities import EntityStatus as ES

                    # Union-Find to discover connected components via fluidbox_neighbours
                    parent = {e.id: e.id for e in all_handlers_with_neighbours}

                    def find(x):
                        while parent[x] != x:
                            parent[x] = parent[parent[x]]
                            x = parent[x]
                        return x

                    def union(a, b):
                        ra, rb = find(a), find(b)
                        if ra != rb:
                            parent[ra] = rb

                    # Track actual edges discovered (for coverage checking)
                    component_edges = {}  # root -> list of (id_a, id_b)

                    for handler in all_handlers_with_neighbours:
                        for neighbour_id in handler.fluidbox_neighbours:
                            if neighbour_id in id_to_handler:
                                union(handler.id, neighbour_id)

                    # Collect components
                    components = {}
                    for handler in all_handlers_with_neighbours:
                        root = find(handler.id)
                        if root not in components:
                            components[root] = []
                        components[root].append(handler)

                    # Rebuild edges per component (after union-find is settled)
                    for root, members in components.items():
                        edges = []
                        member_ids = {m.id for m in members}
                        for m in members:
                            for neighbour_id in m.fluidbox_neighbours:
                                if neighbour_id in member_ids and m.id < neighbour_id:
                                    edges.append((m.id, neighbour_id))
                        component_edges[root] = edges

                    # Create new PipeGroups only for components that have at
                    # least one edge NOT already covered by an existing PipeGroup.
                    # This is edge-level, not entity-level: entities A, B, C might
                    # all appear in existing groups, but if A↔B is a NEW connection
                    # (e.g. steam vs water), it still gets its own group.
                    synthetic_id = -1
                    for root, members in components.items():
                        edges = component_edges[root]
                        # Skip if every edge in this component is already covered
                        if edges and all(edge_already_covered(a, b) for a, b in edges):
                            continue
                        # Also skip single-entity components with no edges
                        if not edges:
                            continue
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
                        Prototype.Substation,
                    )
                ]
                power_switches = [
                    entity
                    for entity in entities_list
                    if hasattr(entity, "name") and entity.name == "power-switch"
                ]
                group = agglomerate_groupable_entities(poles, power_switches=power_switches)
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
                                Prototype.Substation,
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
