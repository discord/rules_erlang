load(
    "//tools:erlang_toolchain.bzl",
    "erlang_dirs",
    "erl_rootdir_setup",
    "version_file",
)

def _impl(ctx):
    (erlang_home, _, runfiles) = erlang_dirs(ctx)

    script = """#!/usr/bin/env bash
set -euo pipefail

{erl_rootdir_setup}

exec \\
    env ERLANG_HOME="{erlang_home}" \\
        VERSION_FILE="{version_file}" \\
    "{erlang_home}"/bin/escript "{escript}" $@
""".format(
        erl_rootdir_setup = erl_rootdir_setup(ctx, runfiles = True),
        erlang_home = erlang_home,
        version_file = version_file(ctx).short_path,
        escript = ctx.file.escript.short_path,
    )

    ctx.actions.write(
        output = ctx.outputs.out,
        content = script,
        is_executable = True,
    )

    runfiles = runfiles.merge(
        ctx.runfiles(files = ctx.files.escript),
    )

    return [
        DefaultInfo(
            runfiles = runfiles,
            executable = ctx.outputs.out,
        ),
    ]

escript_wrapper = rule(
    implementation = _impl,
    attrs = {
        "escript": attr.label(
            mandatory = True,
            allow_single_file = True,
        ),
        "out": attr.output(
            mandatory = True,
        ),
    },
    toolchains = ["//tools:toolchain_type"],
    executable = True,
)
