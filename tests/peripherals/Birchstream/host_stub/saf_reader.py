#!/usr/bin/env python3
"""
eSPI SAF Reader — Trace-driven flash read replay.
Reference: Birchstream Simics espi_saf_orchestrator.py

Replays captured SAF read requests through the eSPI controller's
HandleSafRead method. Deterministic: same addresses, same results.
"""

from dataclasses import dataclass, field
from typing import List


@dataclass
class SafReadRequest:
    """Single SAF read in a trace."""
    host_address: int
    length: int
    tag: int = 0
    description: str = ""


@dataclass
class SafReaderTrace:
    """Ordered sequence of SAF reads to replay."""
    name: str
    reads: List[SafReadRequest] = field(default_factory=list)


# Birchstream BIOS read sequence
BIRCHSTREAM_BIOS_READ = SafReaderTrace(
    name="birchstream_bios_read",
    reads=[
        SafReadRequest(0x00000000, 64, description="BIOS header (first 64B)"),
        SafReadRequest(0x00000040, 64, description="BIOS header (next 64B)"),
        SafReadRequest(0x00000080, 64, description="BIOS entry vectors"),
        SafReadRequest(0x00000100, 64, description="BIOS code start"),
    ]
)

# Birchstream OS image header read
BIRCHSTREAM_OS_HEADER = SafReaderTrace(
    name="birchstream_os_header",
    reads=[
        SafReadRequest(0x01000000, 64, description="SAF boot header (first 64B)"),
        SafReadRequest(0x01000040, 32, description="SAF boot header (last 32B)"),
    ]
)


def generate_robot_keyword(trace: SafReaderTrace) -> str:
    """Generate Robot Framework keyword for a SAF read trace."""
    lines = []
    lines.append(f"Replay SAF {trace.name}")
    lines.append(f"    [Documentation]    Replay {trace.name} SAF read sequence")

    for i, read in enumerate(trace.reads):
        lines.append(f"    # Step {i}: {read.description}")
        lines.append(f"    Execute Command    espi HandleSafRead "
                     f"0x{read.host_address:08X} {read.length} {read.tag}")
    return "\n".join(lines)


TRACES = {
    "bios_read": BIRCHSTREAM_BIOS_READ,
    "os_header": BIRCHSTREAM_OS_HEADER,
}
