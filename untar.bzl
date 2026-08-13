load(":util.bzl", "path_join")

# TODO(denbeigh): this should all be ripped out when we drop support for
# OTP<25 (versions without a relocatable installation directory)
def _impl(ctx):
    outputs = [
        ctx.actions.declare_file(f.name)
        for f in ctx.attr.outs
    ]

    args = ctx.actions.args()
    args.add("-x")
    args.add("--no-same-owner")
    args.add("--file")
    args.add(ctx.file.archive)
    args.add("--directory")
    args.add(path_join(
        ctx.bin_dir.path,
        ctx.label.workspace_root,
        ctx.label.package,
    ))

    ctx.actions.run(
        outputs = outputs,
        inputs = ctx.files.archive,
        executable = "tar",
        mnemonic = "ErlUntar",
        arguments = [args],
    )

    return [DefaultInfo(files = depset(outputs))]

untar = rule(
    implementation = _impl,
    attrs = {
        "archive": attr.label(
            allow_single_file = True,
            mandatory = True,
        ),
        "outs": attr.output_list(
            mandatory = True,
        ),
    },
)
