from .privileged import call


def rgb_supported():
    try:
        return get_rgb() is not None
    except Exception:
        return False


def get_rgb():
    return call("get_rgb")


def set_rgb(enabled, color, brightness, effect="static", speed=100):
    return call(
        "set_rgb",
        enabled=enabled,
        color=color,
        brightness=brightness,
        effect=effect,
        speed=speed,
    )


# armada#23: an orthogonal toggle (dedicated `sync-brightness on|off`
# command), not an --effect value -- see the RgbEffect note in the frontend
# types.ts.
def set_rgb_sync_brightness(enabled):
    return call("set_rgb_sync_brightness", enabled=enabled)


# armada#26: opt-in gate the suspend hook reads directly (not armada-rgb's
# own config) -- default OFF, Jordi 2026-09-18.
def get_rgb_charge_indicator_enabled():
    return call("get_rgb_charge_indicator_enabled")


def set_rgb_charge_indicator_enabled(enabled):
    return call("set_rgb_charge_indicator_enabled", enabled=enabled)
