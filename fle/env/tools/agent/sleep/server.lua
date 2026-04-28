global.actions.sleep = function(seconds)
    -- NOTE: This used to bump global.elapsed_ticks by seconds*60 immediately,
    -- before any real ticks elapsed. That made elapsed_ticks lie when the
    -- engine couldn't sustain the requested speed (truncated sleeps reported
    -- the full requested count). The bump is now done from the client
    -- (Sleep.__call__) AFTER the wait completes, using the actual game.tick
    -- delta — so global.elapsed_ticks reflects in-game time that really
    -- passed, even on truncated/paused/disconnected sleeps.
    return game.tick
end