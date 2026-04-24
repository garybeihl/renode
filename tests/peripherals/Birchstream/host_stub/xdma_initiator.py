#!/usr/bin/env python3
"""
XDMA Initiator — Trace-driven DMA descriptor chain replay.
Reference: Birchstream Simics xdma_boot_orchestrator.py

Builds descriptor chains in BMC SRAM and triggers DMA transfers.
Deterministic: same descriptors, same results.
"""

import struct
from dataclasses import dataclass, field
from typing import List


@dataclass
class XdmaDescriptor:
    """Single DMA descriptor."""
    src_addr: int
    dst_addr: int
    length: int
    flags: int = 0
    description: str = ""

    def pack(self) -> bytes:
        return struct.pack("<IIII", self.src_addr, self.dst_addr, self.length, self.flags)


@dataclass
class XdmaTransferTrace:
    """Complete XDMA transfer operation."""
    name: str
    queue_base: int = 0x10000000  # SRAM
    queue_size: int = 0x1000
    descriptors: List[XdmaDescriptor] = field(default_factory=list)


# Birchstream 2MB OS image transfer (4 x 512KB chunks)
BIRCHSTREAM_OS_TRANSFER = XdmaTransferTrace(
    name="birchstream_os_transfer",
    descriptors=[
        XdmaDescriptor(0x82000060, 0x80100000, 0x80000,
                       description="OS image chunk 0 (512KB)"),
        XdmaDescriptor(0x82080060, 0x80180000, 0x80000,
                       description="OS image chunk 1 (512KB)"),
        XdmaDescriptor(0x82100060, 0x80200000, 0x80000,
                       description="OS image chunk 2 (512KB)"),
        XdmaDescriptor(0x82180060, 0x80280000, 0x80000,
                       description="OS image chunk 3 (512KB)"),
    ]
)


def generate_robot_keyword(trace: XdmaTransferTrace) -> str:
    """Generate Robot Framework keyword for XDMA transfer."""
    lines = []
    lines.append(f"Replay XDMA {trace.name}")
    lines.append(f"    [Documentation]    Replay {trace.name} XDMA transfer")

    # Setup queue
    lines.append(f"    Execute Command    xdma WriteDoubleWord 0x014 "
                 f"0x{trace.queue_base:08X}")
    lines.append(f"    Execute Command    xdma WriteDoubleWord 0x018 "
                 f"0x{trace.queue_size:X}")
    lines.append(f"    Execute Command    xdma WriteDoubleWord 0x020 0x0")
    # Enable DS_COMP IRQ
    lines.append(f"    Execute Command    xdma WriteDoubleWord 0x038 0x00020000")

    # Write descriptors
    for i, desc in enumerate(trace.descriptors):
        base = trace.queue_base + i * 16
        lines.append(f"    # Descriptor {i}: {desc.description}")
        lines.append(f"    Execute Command    sysbus WriteDoubleWord "
                     f"0x{base:08X} 0x{desc.src_addr:08X}")
        lines.append(f"    Execute Command    sysbus WriteDoubleWord "
                     f"0x{base + 4:08X} 0x{desc.dst_addr:08X}")
        lines.append(f"    Execute Command    sysbus WriteDoubleWord "
                     f"0x{base + 8:08X} 0x{desc.length:08X}")
        lines.append(f"    Execute Command    sysbus WriteDoubleWord "
                     f"0x{base + 12:08X} 0x{desc.flags:08X}")

    # Trigger
    lines.append(f"    Execute Command    xdma WriteDoubleWord 0x01C "
                 f"0x{len(trace.descriptors):X}")

    return "\n".join(lines)


TRACES = {
    "os_transfer": BIRCHSTREAM_OS_TRANSFER,
}
