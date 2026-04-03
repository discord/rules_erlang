"""Configuration transitions for architecture-independent BEAM outputs.

BEAM bytecode (.beam) and app metadata (.app) are architecture-independent.
These transitions normalize the CPU in the target configuration so that
Bazel's action cache deduplicates across architectures — compile once,
reuse everywhere, pair with arch-specific ERTS at the container/release layer.

When //:erlang_platform is set to an OTP-only platform
(e.g. @erlang_config//:erlang_26_3_platform), the transition uses that
platform instead of clearing to []. This preserves OTP version constraints
for correct toolchain resolution when multiple OTP versions are registered,
while still stripping CPU/OS for cache dedup.

When the flag is empty (default), behavior is unchanged: --platforms is
cleared to [], and toolchain resolution falls back to the default
constraint_value — safe for the single-OTP case.
"""

def _platform_independent_impl(settings, attr):
    erlang_platform = settings["//:erlang_platform"]
    if erlang_platform:
        return {"//command_line_option:platforms": [erlang_platform]}
    else:
        return {"//command_line_option:platforms": []}

platform_independent_transition = transition(
    implementation = _platform_independent_impl,
    inputs = [
        "//command_line_option:platforms",
        "//:erlang_platform",
    ],
    outputs = ["//command_line_option:platforms"],
)
