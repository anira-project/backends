#!/usr/bin/env python3
# Export a trivial add model (a + b) to an ExecuTorch .pte using the CPU portable backend —
# no delegate, so it runs on the optimized/portable kernels the packaged runtime always
# carries. Used only by the smoke test (test/CMakeLists.txt) to produce a real model the
# C++ runtime loads + executes. Requires the `executorch` + `torch` python wheels pinned to
# engines/executorch/VERSION; when they are unavailable the smoke falls back to a link-only
# check, so a failure here is non-fatal to the build.
#
# Usage: export_add.py <output.pte>
import sys

import torch
from torch.export import export
from executorch.exir import to_edge


class Add(torch.nn.Module):
    def forward(self, a, b):
        return a + b


def main() -> int:
    out = sys.argv[1] if len(sys.argv) > 1 else "add.pte"
    example = (torch.ones(3), torch.ones(3))
    exported = export(Add(), example)
    program = to_edge(exported).to_executorch()
    with open(out, "wb") as f:
        f.write(program.buffer)
    print(f"wrote {out} ({len(program.buffer)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
