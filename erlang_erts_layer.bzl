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
        "erlang_home": "Path where ERTS is installed in the tar (/lib/erlang)",
        "erts_version": "ERTS version from OtpInfo",
    },
)

def _erlang_erts_layer_impl(ctx):
    otp_info = ctx.attr.erlang[OtpInfo]

    if otp_info.release_dir_tar == None:
        fail("erlang target must provide a release_dir_tar (external erlang not supported)")

    # Declare output tar file
    output_tar = ctx.actions.declare_file(ctx.label.name + ".tar")

    # Create script to extract and repackage the tar
    # The input tar contains lib/erlang/..., we want opt/erlang/...
    ctx.actions.run_shell(
        inputs = [otp_info.release_dir_tar],
        outputs = [output_tar],
        command = """set -euo pipefail

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

cd "$WORK_DIR"

# Extract the release tar
tar -xf {input_tar}

# Re-tar without transformation
tar -cf {output_tar} lib/erlang

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
    attrs = {
        "erlang": attr.label(
            mandatory = True,
            providers = [OtpInfo],
            doc = "The Erlang/OTP installation to package (must be erlang_build, not erlang_external)",
        ),
    },
    doc = """Create a tar layer containing ERTS runtime for distroless containers.

This rule takes an Erlang/OTP installation and packages it as a tar layer
suitable for use in OCI images. The ERTS runtime is installed at /lib/erlang
in the resulting tar.

Example:
    erlang_erts_layer(
        name = "erts_layer",
        erlang = "@otp_26",
    )

The output tar can be used directly in oci_image:
    oci_image(
        name = "my_image",
        tars = [":erts_layer"],
        env = {"ERLANG_HOME": "/lib/erlang"},
    )
""",
)
