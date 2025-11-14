"""
Takes a compiled BEAM application (ErlangAppInfo/.app+.beam files)
Outputs release-specific assets (ErlangReleaseInfo/vm args+boot scripts+bytecode+app info)
"""
load(
    "//:erlang_app_info.bzl",
    "ErlangAppInfo",
    "flat_deps",
)
load(
    "//tools:erlang_toolchain.bzl",
    "erlang_dirs",
    "maybe_install_erlang",
)

ErlangReleaseInfo = provider(
    doc = "Information about an Erlang release",
    fields = {
        "rel_file": "Path to .rel file",
        "script_file": "Path to .script file",
        "boot_file": "Path to .boot file",
        "manifest_file": "EETF-encoded map of app_name -> version",
        "app_name": "Name of main app",
        "app_info": "ErlangAppInfo of released app",
        "release_name": "Name of the release",
        "release_version": "Version of the release",
        "sys_config": "Optional sys.config File object",
    },
)

def _extract_app_info(dep):
    """Extract app name and version from an ErlangAppInfo provider."""
    app_info = dep[ErlangAppInfo]
    app_name = app_info.app_name

    # Try to get version from the .app file if it exists
    app_version = "0.0.0"  # Default version
    for f in app_info.beam:
        if f.basename == "{}.app".format(app_name):
            # We'll extract version at build time from the .app file
            # For now, use a placeholder that will be replaced
            app_version = "__VERSION_FROM_APP__"
            break

    # Get the directory containing the app's beam files
    app_dir = None
    for f in app_info.beam:
        if f.is_directory:
            app_dir = f.path
            break
        else:
            # Use the parent directory of the beam file
            app_dir = f.dirname
            break

    return (app_name, app_version, app_dir, app_info.beam)

def _impl(ctx):
    app_info = ctx.attr.app[ErlangAppInfo]
    app_name = app_info.app_name

    # Use provided release name/version or default to app name/version
    release_name = ctx.attr.release_name if ctx.attr.release_name else app_name
    release_version = ctx.attr.release_version if ctx.attr.release_version else "1.0.0"

    # Declare output files
    rel_file = ctx.actions.declare_file("{}.rel".format(release_name))
    script_file = ctx.actions.declare_file("{}.script".format(release_name))
    boot_file = ctx.actions.declare_file("{}.boot".format(release_name))
    manifest_file = ctx.actions.declare_file("{}.manifest".format(release_name))

    # Get all dependencies including the main app
    all_deps = flat_deps([ctx.attr.app])

    # Collect dependency information
    deps_info = []
    app_dirs = []
    all_beam_files = []

    for dep in all_deps:
        dep_name, dep_version, dep_dir, beam_files = _extract_app_info(dep)
        deps_info.append((dep_name, dep_version, dep_dir))
        if dep_dir:
            app_dirs.append(dep_dir)
        all_beam_files.extend(beam_files)

    # Get Erlang toolchain
    (erlang_home, _, runfiles) = erlang_dirs(ctx)

    # Get build_release tool path
    build_release_path = ctx.attr._build_release_tool[DefaultInfo].files_to_run.executable.path

    # Build the dependency info term to pass via stdin
    # Pass pairs of {AppName, AppDir} - the Erlang tool will extract versions
    deps_term_lines = []
    for dep_name, _, dep_dir in deps_info:
        # dep_name needs to be an atom in Erlang (no quotes)
        deps_term_lines.append("  {{{},\"{}\"}}".format(dep_name, dep_dir))

    # Build the extra OTP apps list
    extra_apps_terms = []
    for extra_app in ctx.attr.extra_apps:
        extra_apps_terms.append("  {}".format(extra_app))

    # Create the shell script to run the build_release tool
    script = """set -euo pipefail

{maybe_install_erlang}

# Set up ERL_LIBS to include OTP libraries so build_release.erl can find them
export ERL_LIBS="{erlang_home}/lib"

# Create output directory
output_dir=$(dirname "{rel_file}")
mkdir -p "$output_dir"

# Run the build_release tool with dependency list via heredoc
"{erlang_home}"/bin/escript "{build_release}" \\
    "{app_name}" \\
    "{app_version}" \\
    "$output_dir" \\
    "{release_name}" \\
    "{release_version}" <<'EOF'
{{[
{deps_list}
], [
{extra_apps}
]}}.
EOF

# Verify outputs were created
if [[ ! -f "{rel_file}" ]]; then
    echo "Error: Release file {rel_file} was not created"
    exit 1
fi

if [[ ! -f "{script_file}" ]]; then
    echo "Error: Script file {script_file} was not created"
    exit 1
fi

if [[ ! -f "{boot_file}" ]]; then
    echo "Error: Boot file {boot_file} was not created"
    exit 1
fi
""".format(
        maybe_install_erlang = maybe_install_erlang(ctx),
        erlang_home = erlang_home,
        build_release = build_release_path,
        app_name = app_name,
        app_version = ctx.attr.app_version if ctx.attr.app_version else "1.0.0",
        release_name = release_name,
        release_version = release_version,
        rel_file = rel_file.path,
        script_file = script_file.path,
        boot_file = boot_file.path,
        deps_list = ",\n".join(deps_term_lines),
        extra_apps = ",\n".join(extra_apps_terms) if extra_apps_terms else "",
    )

    # Merge runfiles from the tool
    runfiles = runfiles.merge(
        ctx.attr._build_release_tool[DefaultInfo].default_runfiles,
    )

    # Create inputs
    inputs = depset(
        direct = all_beam_files,
        transitive = [runfiles.files],
    )

    # Run the action
    ctx.actions.run_shell(
        inputs = inputs,
        outputs = [rel_file, script_file, boot_file, manifest_file],
        command = script,
        mnemonic = "ErlangRelease",
        progress_message = "Generating Erlang release for {}".format(release_name),
    )

    return [
        DefaultInfo(
            files = depset([rel_file, script_file, boot_file, manifest_file]),
            runfiles = ctx.runfiles(files = [rel_file, script_file, boot_file, manifest_file]),
        ),
        ErlangReleaseInfo(
            rel_file = rel_file,
            script_file = script_file,
            boot_file = boot_file,
            manifest_file = manifest_file,
            app_name = app_name,
            app_info = ctx.attr.app[ErlangAppInfo],
            release_name = release_name,
            release_version = release_version,
            sys_config = None,  # TODO: Add sys_config support to erlang_release rule
        ),
    ]

erlang_release = rule(
    implementation = _impl,
    attrs = {
        "app": attr.label(
            mandatory = True,
            providers = [ErlangAppInfo],
            doc = "The target providing ErlangAppInfo for the main application",
        ),
        "app_version": attr.string(
            doc = "Version of the main application (optional, defaults to 1.0.0)",
        ),
        "release_name": attr.string(
            doc = "Name of the release (optional, defaults to app name)",
        ),
        "release_version": attr.string(
            doc = "Version of the release (optional, defaults to 1.0.0)",
        ),
        "extra_apps": attr.string_list(
            default = [],
            doc = "Additional OTP applications to include (e.g., ['compiler', 'crypto', 'ssl'])",
        ),
        "_build_release_tool": attr.label(
            default = Label("//tools/build_release"),
            executable = True,
            cfg = "target",
        ),
    },
    toolchains = ["//tools:toolchain_type"],
    doc = """Generate an Erlang release from an application.

This rule creates .rel, .script, and .boot files for an Erlang release
using SASL's systools:make_script/2. It accepts any target that provides
ErlangAppInfo, including apps from rules_erlang and rules_elixir.

Example:
    erlang_release(
        name = "my_release",
        app = "//my_app:erlang_app",
        release_name = "prod",
        release_version = "1.0.0",
    )

This will generate:
    - prod.rel: Release specification file
    - prod.script: Human-readable boot script
    - prod.boot: Binary boot file for the Erlang VM
""",
)
