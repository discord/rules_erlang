"""
Create a tar layer containing ERTS runtime for use in distroless containers.
"""

ErtsLayerInfo = provider(
    doc = "Information about an ERTS layer tar file",
    fields = {
        "tar": "Tar file containing the ERTS runtime",
        "erlang_home": "Path where ERTS is installed in the tar (/lib/erlang)",
        "erts_version": "ERTS version from OtpInfo",
    },
)

def _erlang_erts_layer_impl(ctx):
    tc = ctx.toolchains["//tools:toolchain_type"]
    if tc == None:
        fail("No Erlang toolchain found matching the target platform. " +
             "Did you register an Erlang toolchain with appropriate target_compatible_with constraints?")
    otp_info = tc.otpinfo

    if otp_info.release_dir_tar == None:
        fail("erlang target must provide a release_dir_tar (external erlang not supported)")

    # Declare output tar file
    output_tar = ctx.actions.declare_file(ctx.label.name + ".tar")

    # Create script to extract and repackage the tar
    # The input tar contains lib/erlang/, bin/, etc. - we extract just lib/erlang
    ctx.actions.run_shell(
        inputs = [otp_info.release_dir_tar],
        outputs = [output_tar],
        command = """set -euo pipefail

ABS_INPUT_TAR="$PWD/{input_tar}"
ABS_OUTPUT_TAR="$PWD/{output_tar}"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

cd "$WORK_DIR"

tar --no-same-owner -xf "$ABS_INPUT_TAR"
tar -cf "$ABS_OUTPUT_TAR" lib/erlang

""".format(
            input_tar = otp_info.release_dir_tar.path,
            output_tar = output_tar.path,
        ),
        mnemonic = "ErtsLayer",
        progress_message = "Creating ERTS layer tar for {}".format(ctx.label.name),
    )

    return [
        DefaultInfo(
            files = depset([output_tar]),
        ),
        ErtsLayerInfo(
            tar = output_tar,
            erlang_home = "/lib/erlang",
            erts_version = otp_info.version,
        ),
    ]

erlang_erts_layer = rule(
    implementation = _erlang_erts_layer_impl,
    attrs = {},
    toolchains = ["//tools:toolchain_type"],
    doc = """Create a tar layer containing ERTS runtime for distroless containers.

This rule resolves the Erlang/OTP installation via toolchain resolution,
making it platform-aware. When built under a platform transition, the
correct architecture's ERTS will be selected automatically.

The ERTS runtime is installed at /lib/erlang in the resulting tar.

Example:
    erlang_erts_layer(
        name = "erts_layer",
    )

The output tar can be used directly in oci_image:
    oci_image(
        name = "my_image",
        tars = [":erts_layer"],
        env = {"ERLANG_HOME": "/lib/erlang"},
    )
""",
)
