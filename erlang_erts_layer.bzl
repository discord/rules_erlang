"""
Create a tar layer containing ERTS runtime for use in distroless containers.
"""

load(
    "//private:erlang_build.bzl",
    "OtpInfo",
)

ErtsLayerInfo = provider(
    doc = "Information about an ERTS layer tar file",
    fields = {
        "tar": "Tar file containing the ERTS runtime",
        "erlang_home": "Path where ERTS is installed in the tar",
        "erts_version": "ERTS version from OtpInfo",
    },
)

def _erlang_erts_layer_impl(ctx):
    otp_info = ctx.attr.otp[OtpInfo]

    if otp_info.release_dir_tar == None:
        fail("otp target must provide a release_dir_tar (external erlang not supported)")

    # Declare output tar file
    output_tar = ctx.actions.declare_file(ctx.label.name + ".tar")

    # The release tar already has the flat release layout (bin/, lib/,
    # erts-X.Y.Z/) at root. We repackage it under a prefix so the
    # container layer installs ERTS at a known absolute path.
    install_prefix = "/opt/erlang"

    ctx.actions.run_shell(
        inputs = [otp_info.release_dir_tar],
        outputs = [output_tar],
        command = """set -euo pipefail

ABS_INPUT_TAR="$PWD/{input_tar}"
ABS_OUTPUT_TAR="$PWD/{output_tar}"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR{install_prefix}"
tar --no-same-owner -xf "$ABS_INPUT_TAR" -C "$WORK_DIR{install_prefix}"
tar -cf "$ABS_OUTPUT_TAR" -C "$WORK_DIR" .{install_prefix}

""".format(
            input_tar = otp_info.release_dir_tar.path,
            output_tar = output_tar.path,
            install_prefix = install_prefix,
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
            erlang_home = install_prefix,
            erts_version = otp_info.version,
        ),
    ]

erlang_erts_layer = rule(
    implementation = _erlang_erts_layer_impl,
    attrs = {
        "otp": attr.label(
            mandatory = True,
            providers = [OtpInfo],
            doc = """An erlang_build target providing the OTP release tar.

Use select() to pick the correct architecture:
    otp = select({
        "@platforms//cpu:x86_64": "@erlang_config//25_amd64:otp-25_amd64",
        "@platforms//cpu:aarch64": "@erlang_config//25_arm64:otp-25_arm64",
    })
""",
        ),
    },
    doc = """Create a tar layer containing ERTS runtime for distroless containers.

Takes an erlang_build target directly, bypassing toolchain resolution.
This allows building ERTS layers for foreign architectures (e.g. arm64
on an x86_64 host) since the rule only repackages the pre-built release
tar without executing any arch-specific code.

Use select() on @platforms//cpu to pick the correct OTP target per
architecture. Platform transitions (e.g. from elixir_container_image)
set --platforms before this rule is analyzed, so select() resolves
to the correct arch.

The ERTS runtime is installed at /opt/erlang in the resulting tar.

Example:
    erlang_erts_layer(
        name = "erts_layer",
        otp = select({
            "@platforms//cpu:x86_64": "@erlang_config//25_amd64:otp-25_amd64",
            "@platforms//cpu:aarch64": "@erlang_config//25_arm64:otp-25_arm64",
        }),
    )

The output tar can be used directly in oci_image:
    oci_image(
        name = "my_image",
        tars = [":erts_layer"],
        env = {"ERLANG_HOME": "/opt/erlang"},
    )
""",
)
