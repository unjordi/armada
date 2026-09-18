import os
import shlex
import subprocess
from pathlib import Path

from .privileged import call


OS_VERSION_PATH = Path("/usr/lib/armada/version")
# Sleep-mode labels and the mode menu are owned by the privileged backend (see
# armada-control's sleep_modes); this module consumes them via `call` so there
# is a single source of truth. DESKTOP_MODE_LABELS stays local: desktop modes
# have no backend menu action.
DESKTOP_MODE_LABELS = {
    "mobile": "Plasma Mobile",
    "desktop": "Plasma Desktop"
}


def run_cmd(cmd, timeout=5, capture=True):
    try:
        return subprocess.run(
            cmd,
            check=False,
            text=True,
            stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=timeout,
        )
    except (OSError, subprocess.SubprocessError):
        return None


def device_env():
    try:
        env = call("get_device_env").get("env")
        if isinstance(env, dict):
            return {str(k): str(v) for k, v in env.items()}
    except Exception:
        pass
    helper = os.environ.get("ARMADA_DEVICE_ENV", "/usr/libexec/armada/device-env")
    proc = run_cmd([helper])
    env = {}
    if proc is None:
        return env
    for line in proc.stdout.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            try:
                env[key] = shlex.split(value)[0] if value else ""
            except ValueError:
                env[key] = value
    return env


def ssh_enabled():
    try:
        return bool(call("get_ssh_enabled").get("enabled"))
    except Exception:
        pass
    active = run_cmd(["/usr/bin/systemctl", "is-active", "sshd"])
    active_s = active.stdout.strip() if active else ""
    return active_s == "active"


def mtp_enabled():
    try:
        return bool(call("get_mtp_enabled").get("enabled"))
    except Exception:
        pass
    active = run_cmd(["/usr/bin/systemctl", "is-active", "armada-mtp.service"])
    active_s = active.stdout.strip() if active else ""
    return active_s == "active"


def abl_auto_enabled():
    try:
        return bool(call("get_abl_auto_enabled").get("enabled"))
    except Exception:
        return False


def os_version():
    return read_text(OS_VERSION_PATH) or "unknown"


def abl_version():
    try:
        return str(call("get_abl_version").get("version") or "unknown")
    except Exception:
        return "unknown"


def read_text(path):
    try:
        return path.read_text(encoding="utf-8", errors="replace").strip()
    except OSError:
        return ""


def set_ssh_enabled(enabled):
    return bool(call("set_ssh_enabled", enabled=bool(enabled)).get("enabled"))


def set_mtp_enabled(enabled):
    return bool(call("set_mtp_enabled", enabled=bool(enabled)).get("enabled"))


def set_abl_auto_enabled(enabled):
    return bool(call("set_abl_auto_enabled", enabled=bool(enabled)).get("enabled"))


def bottom_screen_enabled():
    try:
        return bool(call("get_bottom_screen_enabled").get("enabled"))
    except Exception:
        return False


def set_bottom_screen_enabled(enabled):
    return bool(call("set_bottom_screen_enabled", enabled=bool(enabled)).get("enabled"))


def bottom_screen_brightness():
    try:
        result = call("get_bottom_screen_brightness")
        if result.get("supported"):
            return int(result.get("brightness", 0))
    except Exception:
        pass
    return None


def bottom_screen_active():
    try:
        return bool(call("get_bottom_screen_brightness").get("active"))
    except Exception:
        return False


def set_bottom_screen_brightness(brightness):
    return int(call("set_bottom_screen_brightness", brightness=brightness).get("brightness", 0))


def desktop_mode() -> str:
    try:
        value = str(call("get_desktop_mode").get("value", ""))
    except Exception:
        return "desktop"

    return value if value in DESKTOP_MODE_LABELS else "desktop"


def set_desktop_mode(value: str) -> str:
    return str(
        call("set_desktop_mode", value=str(value)).get("value")
    )

def desktop_modes():
    modes = ["desktop", "mobile"]
    return [{"data": mode, "label": DESKTOP_MODE_LABELS[mode]} for mode in modes]

def sleep_modes():
    # Single source of truth: the privileged backend owns the fleet's sleep-mode
    # menu (which modes exist, and which are greyed out because the model is not
    # validated for deep). The plugin consumes it rather than re-deriving from
    # mem_sleep, so display and enforcement never drift. If the backend is
    # unreachable, fall back to the always-safe "fake" only.
    try:
        modes = call("get_sleep_modes").get("modes")
        if isinstance(modes, list):
            return modes
    except Exception:
        pass
    return [{"data": "fake", "label": "Fake", "disabled": False}]


def set_sleep_mode(value):
    return str(call("set_sleep_mode", value=str(value)).get("value"))


CORE_PRESET_VARS = (
    ("big", "Big Cores", "ARMADA_BIG_CORES"),
    ("prime", "Prime Cores", "ARMADA_PRIME_CORES"),
    ("little", "Little Cores", "ARMADA_LITTLE_CORES"),
)


def perf_info():
    governors = [
        g for g in read_text(
            Path("/sys/devices/system/cpu/cpufreq/policy0/scaling_available_governors")
        ).split()
        # userspace = kernel does no scaling, waits for a scaling_setspeed
        # writer; nothing on the image writes it, so it would freeze clocks.
        if g != "userspace"
    ]
    schedulers = ["eevdf"] + [
        name for name in ("cosmos", "lavd") if Path(f"/usr/bin/scx_{name}").exists()
    ]
    env = device_env()
    presets = [{"data": "all", "label": "All Cores"}]
    for key, label, var in CORE_PRESET_VARS:
        cpulist = env.get(var, "")
        if cpulist:
            presets.append({"data": key, "label": f"{label} ({cpulist})"})
    return {
        "governors": governors,
        "schedulers": schedulers,
        "corePresets": presets,
        "cpuCount": os.cpu_count() or 8,
    }


def reapply_perf():
    return call("reapply_perf")


def restart_game_mode():
    return bool(call("restart_game_mode").get("ok"))
