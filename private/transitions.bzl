"""Configuration transitions for architecture-independent BEAM outputs.

BEAM bytecode (.beam) and app metadata (.app) are architecture-independent.
These transitions normalize the CPU in the target configuration so that
Bazel's action cache deduplicates across architectures — compile once,
reuse everywhere, pair with arch-specific ERTS at the container/release layer.
"""

def _platform_independent_impl(settings, attr):
    return {"//command_line_option:platforms": []}

platform_independent_transition = transition(
    implementation = _platform_independent_impl,
    inputs = ["//command_line_option:platforms"],
    outputs = ["//command_line_option:platforms"],
)
