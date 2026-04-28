from time import sleep, monotonic

from fle.env.tools import Tool


class Sleep(Tool):
    def __init__(self, connection, game_state):
        super().__init__(connection, game_state)

    # If real game.tick fails to advance for this long, give up. Catches
    # paused-mid-sleep, RCON death, save-loading, etc. Independent of how
    # slow the engine is running — a slow but progressing engine still
    # completes the full wait correctly.
    PROGRESS_STALL_TIMEOUT = 5.0

    def __call__(self, seconds: int) -> bool:
        """
        Sleep until the engine has actually advanced ``seconds * 60`` ticks.

        Polls the real ``game.tick`` instead of pacing wall-clock time by the
        requested ``game.speed``. This keeps the sleep correct when the host
        CPU cannot sustain the requested speed (e.g. ``set_speed(20)`` but
        the machine only delivers 5x).

        Two invariants:
          1. We do not return ``True`` until ``game.tick`` has advanced by at
             least ``seconds * 60``. The only abort path is a progress-stall
             timeout (no tick advance for PROGRESS_STALL_TIMEOUT seconds) →
             returns ``False``.
          2. ``global.elapsed_ticks`` is bumped by the *actual* tick delta
             observed during the wait, not the requested amount. Truncated
             sleeps therefore report truncated elapsed_ticks — downstream
             metrics see ground truth.

        :param seconds: Number of seconds to sleep (in standard 60 ticks/s).
        :return: True if the full wait completed; False if progress stalled.
        """
        ticks_before_real = self._get_real_tick()
        # Server-side action no longer bumps elapsed_ticks; it just returns
        # game.tick. We still call it to keep RCON/Action plumbing identical.
        _, _ = self.execute(seconds)
        ticks_target = ticks_before_real + seconds * 60

        if self._is_paused():
            # Game is frozen — don't busy-wait forever. No ticks elapsed,
            # so don't bump elapsed_ticks either.
            return True

        speed = max(0.1, self.game_state.instance.get_speed())
        # Initial sleep for the best-case duration to avoid hammering RCON.
        best_case_wall = seconds / speed
        sleep(min(best_case_wall, 0.5))

        last_progress_tick = ticks_before_real
        last_progress_wall = monotonic()
        completed = False

        while True:
            tick_now = self._get_real_tick()
            remaining_ticks = ticks_target - tick_now
            if remaining_ticks <= 0:
                completed = True
                break

            if tick_now > last_progress_tick:
                last_progress_tick = tick_now
                last_progress_wall = monotonic()
            elif monotonic() - last_progress_wall > self.PROGRESS_STALL_TIMEOUT:
                # Engine isn't advancing — give up. Bump elapsed_ticks by
                # whatever real progress we observed.
                break

            # Sleep for the estimated time-to-finish, but cap at 0.5s so we
            # notice pauses / speed changes promptly. Min 20ms to avoid
            # busy-looping when very close to target.
            wait = max(0.02, min(0.5, remaining_ticks / 60.0 / speed))
            sleep(wait)

        # Bump global.elapsed_ticks by the *actual* tick delta. This is the
        # bump that used to happen unconditionally in server.lua's sleep
        # action; we moved it here so it reflects reality, not request.
        actual_delta = self._get_real_tick() - ticks_before_real
        if actual_delta > 0:
            try:
                self.game_state.instance.rcon_client.send_command(
                    f"/sc global.elapsed_ticks = (global.elapsed_ticks or 0) + {actual_delta}"
                )
            except Exception:
                pass
        return completed

    def _get_real_tick(self) -> int:
        """Read the actual server game.tick (not global.elapsed_ticks)."""
        try:
            resp = self.game_state.instance.rcon_client.send_command(
                "/sc rcon.print(game.tick)"
            )
            return int(resp.strip())
        except Exception:
            return 0

    def _is_paused(self) -> bool:
        """Check whether the game is paused.

        ``is_paused`` lives on ``GameControl`` (instance.game_control), not on
        ``FactorioInstance`` directly.  Fall back to ``False`` if neither path
        is available so we never block on a missing API.
        """
        instance = self.game_state.instance
        gc = getattr(instance, "game_control", None)
        if gc is not None and hasattr(gc, "is_paused"):
            try:
                return bool(gc.is_paused())
            except Exception:
                return False
        if hasattr(instance, "is_paused"):
            try:
                return bool(instance.is_paused())
            except Exception:
                return False
        return False

