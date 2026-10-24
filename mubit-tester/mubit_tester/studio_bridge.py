"""mubit-tester extension: ForgeBridge Studio plugin tools (studio_status / studio_events / studio_run).

Loaded by server.load_extensions(); the bridge itself lives in forge/bridge.py (docs/STUDIO_PLUGIN.md).
"""

from forge.bridge import register

TOOLS = ("studio_status", "studio_events", "studio_run")

__all__ = ["register", "TOOLS"]
