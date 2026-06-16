load(
    "//private:erlang_build.bzl",
    "OtpInfo",
)

def _impl(ctx):
    otpinfo = ctx.attr.otp[OtpInfo]
    vars = {
        "OTP_VERSION": otpinfo.version,
        "ERLANG_HOME": erlang_home(otpinfo),
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

def erlang_home(otpinfo):
    """The text to write before "/bin/erl" in a generated shell script.

    Two cases, by where the OTP install lives:

    * Host (external) install: erl sits at a fixed path on the machine that we
      already know at analysis time. Return that absolute path; the line
      becomes e.g. "/usr/lib/erlang"/bin/erl.

    * Bazel-managed install (locally-built or prebuilt): erl lives in a Bazel
      tree artifact whose absolute path we do not know at analysis time -- the
      path Bazel gives us is relative, and the absolute location differs by run
      context (build action vs `bazel run` vs `bazel test`).

      In these cases, we return the `$ERL_ROOTDIR` literal, and depend on
      `maybe_install_erlang` to resolve the appropriate path given the context
      (build vs. run/test).

    This is always interpolated into a template, so ensure we fail early if we
    are in an inconsistent state (and never return None).
    """
    if otpinfo.release_dir != None:
        return "$ERL_ROOTDIR"
    if otpinfo.erlang_home == None:
        fail("OtpInfo.erlang_home is None for a non-relocatable (external) " +
             "install. External installs must carry an absolute path; this " +
             "OtpInfo is malformed.")
    return otpinfo.erlang_home

def erlang_dirs(ctx):
    info = _build_info(ctx)

    # erl.exe resolves its root from erl.ini, not $ERL_ROOTDIR, so a relocatable
    # (release_dir) toolchain can't work on a Windows target -- fail loudly here
    # rather than emit a broken .bat. Use a host (external) erlang on Windows.
    if getattr(ctx.attr, "is_windows", False) and info.release_dir != None:
        fail("relocatable OTP toolchain (release_dir) is unsupported on Windows " +
             "targets: erl.exe reads its root from erl.ini, not $ERL_ROOTDIR. " +
             "Use an external (host) erlang toolchain for Windows.")

    if info.release_dir != None:
        runfiles = ctx.runfiles([
            info.release_dir,
            info.version_file,
        ])
    else:
        runfiles = ctx.runfiles([
            info.version_file,
        ])
    return (erlang_home(info), info.release_dir, runfiles)

# TODO: we should probably name thing something that's more relevant.
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
