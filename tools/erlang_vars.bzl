load(":erlang_toolchain.bzl", "erlang_home")

ERLANG_VARS_ENV_MAP = {
    "OTP_VERSION": "$(OTP_VERSION)",
    "OTP_VERSION_FILE_PATH": "$(OTP_VERSION_FILE_PATH)",
    "OTP_VERSION_FILE_SHORT_PATH": "$(OTP_VERSION_FILE_SHORT_PATH)",
    "ERLANG_HOME": "$(ERLANG_HOME)",
}

# relocatable erl finds its root via $ERL_ROOTDIR (absolute only), so we can
# never get away with just using provided relative paths from Bazel.
#
# genrules wanting to run erl should `export ERL_ROOTDIR="$PWD/$(ERLANG_RELEASE_DIR_PATH)"`
# gor _SHORT_PATH in a runfiles context) before invoking "$(ERLANG_HOME)"/bin/erl.
#
# alternatively, one could resolve a specific, configured rule with:
# export ERL_ROOTDIR="$PWD/$(location @erlang_config//...)", _but_ that
# means the genrule will not respsect any toolchain configuration.
ERLANG_VARS_ENV_MAP_INTERNAL = ERLANG_VARS_ENV_MAP | {
    "ERLANG_RELEASE_DIR_PATH": "$(ERLANG_RELEASE_DIR_PATH)",
    "ERLANG_RELEASE_DIR_SHORT_PATH": "$(ERLANG_RELEASE_DIR_SHORT_PATH)",
}

def _impl(ctx):
    otpinfo = ctx.toolchains["//tools:toolchain_type"].otpinfo
    vars = {
        "OTP_VERSION": otpinfo.version,
        "OTP_VERSION_FILE_PATH": otpinfo.version_file.path,
        "OTP_VERSION_FILE_SHORT_PATH": otpinfo.version_file.short_path,
        "ERLANG_HOME": erlang_home(otpinfo),
    }
    if otpinfo.release_dir != None:
        vars["ERLANG_RELEASE_DIR_PATH"] = otpinfo.release_dir.path
        vars["ERLANG_RELEASE_DIR_SHORT_PATH"] = otpinfo.release_dir.short_path

    return [
        platform_common.TemplateVariableInfo(vars),
    ]

erlang_vars = rule(
    implementation = _impl,
    provides = [
        platform_common.TemplateVariableInfo,
    ],
    toolchains = ["//tools:toolchain_type"],
)
