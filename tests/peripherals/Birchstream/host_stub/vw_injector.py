#!/usr/bin/env python3
"""
Virtual Wire Event Injector — Sets host-driven SYSEVT bits.
Reference: Birchstream Simics VW event handling.

Injects host power/reset events via eSPI Virtual Wire system events.
"""

from dataclasses import dataclass, field
from typing import List


@dataclass
class VwEvent:
    """Single Virtual Wire event."""
    name: str
    sysevt_bits: int
    description: str = ""


# Birchstream power-on sequence
BIRCHSTREAM_POWER_ON = [
    VwEvent("PLTRST_DEASSERT", 0x20, "Platform reset deasserted"),
]

# Birchstream graceful shutdown
BIRCHSTREAM_SHUTDOWN = [
    VwEvent("S5_SLEEP", 0x04, "Enter S5 sleep"),
    VwEvent("PLTRST_ASSERT", 0x00, "Platform reset asserted"),
]

# Birchstream warm reset
BIRCHSTREAM_WARM_RESET = [
    VwEvent("HOST_RST_WARN", 0x100, "Host reset warning"),
    VwEvent("PLTRST_ASSERT", 0x00, "Platform reset asserted"),
    VwEvent("PLTRST_DEASSERT", 0x20, "Platform reset deasserted"),
]


def generate_robot_keyword(events: List[VwEvent], name: str) -> str:
    """Generate Robot Framework keyword for VW event sequence."""
    lines = []
    lines.append(f"Inject VW {name}")
    lines.append(f"    [Documentation]    Inject {name} VW event sequence")

    for event in events:
        lines.append(f"    # {event.name}: {event.description}")
        lines.append(f"    Execute Command    espi InjectVwSysevt "
                     f"0x{event.sysevt_bits:08X}")

    return "\n".join(lines)
