load(
    "//private:erlang_build.bzl",
    "OtpInfo",
)

def _impl(ctx):
    otpinfo = ctx.attr.otp[OtpInfo]
    vars = {
        "OTP_VERSION": otpinfo.version,
        "ERLANG_HOME": otpinfo.erlang_home,
    }
    if otpinfo.release_dir != None:
        vars["ERLANG_RELEASE_DIR_PATH"] = otpinfo.release_dir.path
        vars["ERLANG_RELEASE_DIR_SHORT_PATH"] = otpinfo.release_dir.short_path
    return [
        platform_common.ToolchainInfo(otpinfo = otpinfo),
        platform_common.TemplateVariableInfo(vars),
    ]

erlang_toolchain = rule(
    implementation = _impl,
    attrs = {
        "otp": attr.label(
            mandatory = True,
            providers = [OtpInfo],
        ),
    },
    provides = [
        platform_common.ToolchainInfo,
        # Instead of using this toolchain for a genrule,
        # since toolchain resolution won't yet have applied,
        # use @rules_erlang//tools:erlang_vars as a
        # toolchain for genrule rules
        platform_common.TemplateVariableInfo,
    ],
)

def _build_info(ctx):
    return ctx.toolchains["//tools:toolchain_type"].otpinfo

def erlang_dirs(ctx):
    info = _build_info(ctx)
    if info.release_dir != None:
        runfiles = ctx.runfiles([
            info.release_dir,
            info.version_file,
        ])
    else:
        runfiles = ctx.runfiles([
            info.version_file,
        ])
    return (info.erlang_home, info.release_dir, runfiles)

def maybe_install_erlang(ctx, short_path = False):
    # OTP 25+ installs are relocatable: erl honors $ERL_ROOTDIR (falling back to
    # the baked-in path only when unset). So instead of the old mkdir-lock + tar
    # extract into a fixed absolute path, we just point ERL_ROOTDIR at the
    # release_dir tree artifact -- Bazel materializes it like any other input,
    # hermetically and with no shared mutable state. erlang_home is "$ERL_ROOTDIR"
    # (see erlang_dirs / OtpInfo) so consumer templates need no changes.
    info = _build_info(ctx)
    release_dir = info.release_dir
    if release_dir == None:
        # External erlang: erlang_home is already an absolute host path, and
        # ERL_ROOTDIR is left to erl's baked-in default.
        return ""
    if short_path:
        # Executable / test context: the release dir is in the runfiles tree.
        # Under `bazel test`, resolve via $TEST_SRCDIR/$TEST_WORKSPACE; under
        # `bazel run` the cwd is the main-workspace runfiles dir (matching
        # shell.bzl / escript_wrapper), so anchor on $PWD. ERL_ROOTDIR must be
        # absolute (it becomes ROOTDIR for the boot scripts).
        return """\
if [ -n "${{TEST_SRCDIR:-}}" ]; then
    export ERL_ROOTDIR="$TEST_SRCDIR/$TEST_WORKSPACE/{short_path}"
else
    export ERL_ROOTDIR="$PWD/{short_path}"
fi\
""".format(short_path = release_dir.short_path)
    else:
        # Build-action context: cwd is the execroot.
        return 'export ERL_ROOTDIR="$PWD/{}"'.format(release_dir.path)

def version_file(ctx):
    info = _build_info(ctx)
    return info.version_file
