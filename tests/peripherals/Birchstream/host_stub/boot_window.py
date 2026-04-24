#!/usr/bin/env python3
"""
Boot Window Consumer — Reads boot window header and transitions READY->CONSUMED.
Reference: Birchstream Simics espi_boot_window.py
"""

from dataclasses import dataclass


@dataclass
class BootWindowConfig:
    """Boot window configuration."""
    base_address: int = 0x05000000
    magic: int = 0x45535049
    state_offset: int = 0x04

    STATE_EMPTY: int = 0
    STATE_FILLING: int = 1
    STATE_READY: int = 2
    STATE_CONSUMED: int = 3


def generate_robot_keyword() -> str:
    """Generate Robot Framework keyword for boot window consumption."""
    cfg = BootWindowConfig()
    lines = []
    lines.append("Consume Boot Window")
    lines.append("    [Documentation]    Read boot window and transition READY->CONSUMED")

    # Read magic
    lines.append(f"    ${{magic}}=    Execute Command    "
                 f"sysbus ReadDoubleWord 0x{cfg.base_address:08X}")
    lines.append(f"    Should Contain    ${{magic}}    0x{cfg.magic:08X}")

    # Read state
    lines.append(f"    ${{state}}=    Execute Command    "
                 f"sysbus ReadDoubleWord 0x{cfg.base_address + cfg.state_offset:08X}")

    # Read total size
    lines.append(f"    ${{total}}=    Execute Command    "
                 f"sysbus ReadDoubleWord 0x{cfg.base_address + 0x10:08X}")

    # Transition to CONSUMED
    lines.append(f"    Execute Command    sysbus WriteDoubleWord "
                 f"0x{cfg.base_address + cfg.state_offset:08X} "
                 f"0x{cfg.STATE_CONSUMED:X}")

    return "\n".join(lines)
