#!/usr/bin/env python3
"""
KCS IPMI Injector — Trace-driven replay of host IPMI commands.
Reference: Birchstream Simics kcs_bmc_bridge.py

Replays captured IPMI command sequences into LPC/KCS IDR registers.
Deterministic: same trace always produces same result.
"""

import struct
from dataclasses import dataclass, field
from typing import List, Optional, Tuple


@dataclass
class IpmiCommand:
    """Single IPMI command in a trace."""
    net_fn: int
    cmd: int
    data: bytes = b""
    expected_cc: int = 0x00  # expected completion code
    description: str = ""


@dataclass
class KcsInjectorTrace:
    """Ordered sequence of IPMI commands to replay."""
    name: str
    commands: List[IpmiCommand] = field(default_factory=list)


# Birchstream boot discovery sequence (from Simics kcs_bmc_bridge)
BIRCHSTREAM_BOOT_DISCOVERY = KcsInjectorTrace(
    name="birchstream_boot_discovery",
    commands=[
        IpmiCommand(0x06, 0x01, description="Get Device ID"),
        IpmiCommand(0x08, 0x09, b"\x05\x00\x00", description="Get Boot Options (boot flags)"),
        IpmiCommand(0x00, 0x08, description="Get System Boot Options (XDMA metadata)"),
        IpmiCommand(0x08, 0x05, b"\x05\x80\x04\x00\x00", description="Set Boot Options (eSPI SAF)"),
    ]
)


def generate_robot_keywords(trace: KcsInjectorTrace) -> str:
    """Generate Robot Framework keywords for a KCS trace."""
    lines = []
    lines.append(f"Replay {trace.name}")
    lines.append(f"    [Documentation]    Replay {trace.name} IPMI sequence")

    for i, cmd in enumerate(trace.commands):
        data_arg = ""
        if cmd.data:
            hex_bytes = ", ".join(f"0x{b:02X}" for b in cmd.data)
            data_arg = f'"new System.Byte[] {{{hex_bytes}}}"'

        lines.append(f"    # Step {i}: {cmd.description}")
        lines.append(f"    Execute Command    lpc SendHostIpmiCommand "
                     f"0x{cmd.net_fn:02X} 0x{cmd.cmd:02X} {data_arg} 0")

        # Check OBF (auto-response available)
        lines.append(f"    ${{str}}=    Execute Command    lpc ReadDoubleWord 0x3C")
        lines.append(f"    Should Contain    ${{str}}    # Step {i} response pending")

    return "\n".join(lines)


# Pre-built traces for Birchstream
TRACES = {
    "boot_discovery": BIRCHSTREAM_BOOT_DISCOVERY,
}
