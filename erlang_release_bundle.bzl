"""
Takes a built erlang release (ErlangReleaseInfo)
Outputs a directory in standard OTP archive format, suitable for putting into a container or zip archive
"""
load(
    "//:erlang_release.bzl",
    "ErlangReleaseInfo",
)
load(
    "//:erlang_sys_config.bzl",
    "SysConfigInfo",
)
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

def _impl(ctx):
    release_info = ctx.attr.release[ErlangReleaseInfo]

    # Get the release name from the rel file basename
    release_name = release_info.rel_file.basename.removesuffix(".rel")

    # Declare output directory
    bundle_dir = ctx.actions.declare_directory("{}_bundle".format(release_name))

    # Generate the run script from template
    run_script = ctx.actions.declare_file("{}_bundle_run.sh".format(release_name))

    # Expand the template to create the run script
    ctx.actions.expand_template(
        template = ctx.file._run_script_template,
        output = run_script,
        is_executable = True,
        substitutions = {
            "%{release_name}%": release_info.release_name,
            "%{release_version}%": release_info.release_version,
            "%{app_name}%": release_info.app_name,
        },
    )

    # Collect all app infos including the main app and its dependencies
    all_app_infos = [release_info.app_info]  # Start with the main app

    # Add all dependencies
    for dep in release_info.app_info.deps:
        all_app_infos.append(dep[ErlangAppInfo])

    # Get Erlang toolchain
    (erlang_home, _, runfiles) = erlang_dirs(ctx)

    # Collect all input files
    input_files = [
        release_info.rel_file,
        release_info.script_file,
        release_info.boot_file,
        release_info.manifest_file,
        run_script,  # Include the generated run script
    ]

    # Add sys_config file if provided
    sys_config_file = None
    if ctx.attr.sys_config:
        # Try to get the sys.config file from the provider
        # Support both our SysConfigInfo and Elixir's SysConfigInfo
        if SysConfigInfo in ctx.attr.sys_config:
            # Our SysConfigInfo provider
            sys_config_info = ctx.attr.sys_config[SysConfigInfo]
            sys_config_file = sys_config_info.file
        else:
            # Try to get from DefaultInfo (for compatibility with Elixir sys_config)
            # The Elixir rule returns the sys_config in DefaultInfo.files
            default_info = ctx.attr.sys_config[DefaultInfo]
            files = default_info.files.to_list()
            # Look for a .config or sys.config file
            for f in files:
                if f.basename.endswith(".sys.config") or f.basename == "sys.config" or f.basename.endswith(".config"):
                    sys_config_file = f
                    break

        if sys_config_file:
            input_files.append(sys_config_file)
        else:
            fail("Could not find sys.config file from sys_config attribute")

    # Collect beam and priv files from all apps
    for app_info in all_app_infos:
        input_files.extend(app_info.beam)
        input_files.extend(app_info.priv)

    # Generate processing script for each app
    app_processing_lines = []
    for app_info in all_app_infos:
        app_name = app_info.app_name

        # Generate copy commands for beam files
        beam_copy_commands = []
        for f in app_info.beam:
            if f.is_directory:
                beam_copy_commands.append('    cp -r "{}"/* "$APP_DIR/ebin/"'.format(f.path))
            else:
                beam_copy_commands.append('    cp "{}" "$APP_DIR/ebin/"'.format(f.path))

        # Generate copy commands for priv files
        priv_copy_commands = []
        if app_info.priv:
            priv_copy_commands.append('    mkdir -p "$APP_DIR/priv"')
            for f in app_info.priv:
                if f.is_directory:
                    priv_copy_commands.append('    cp -r "{}" "$APP_DIR/priv/"'.format(f.path))
                else:
                    priv_copy_commands.append('    cp -r "{}" "$APP_DIR/priv/"'.format(f.path))

        app_processing_lines.append("""
# Process {app_name}
APP_VERSION=$("{erlang_home}"/bin/erl -noshell -eval '
    {{ok, Binary}} = file:read_file("'$MANIFEST_FILE'"),
    Map = binary_to_term(Binary),
    Version = maps:get({app_name}, Map, <<"0.0.0">>),
    io:format("~s", [Version]),
    halt().' 2>/dev/null)

if [ -n "$APP_VERSION" ]; then
    APP_DIR="$BUNDLE_DIR/lib/{app_name}-$APP_VERSION"
    mkdir -p "$APP_DIR/ebin"

    # Copy beam files
{beam_copies}

    # Copy priv files if they exist
{priv_copies}

    echo "  Copied {app_name}-$APP_VERSION"
fi
""".format(
            app_name = app_name,
            erlang_home = erlang_home,
            beam_copies = "\n".join(beam_copy_commands) if beam_copy_commands else "    # No beam files",
            priv_copies = "\n".join(priv_copy_commands) if priv_copy_commands else "    # No priv files",
        ))

    # Create the shell script to build the bundle
    script = """set -euo pipefail

{maybe_install_erlang}

BUNDLE_DIR="{bundle_dir}"
MANIFEST_FILE="{manifest_file}"
REL_FILE="{rel_file}"
SCRIPT_FILE="{script_file}"
BOOT_FILE="{boot_file}"
RUN_SCRIPT="{run_script}"
RELEASE_NAME="{release_name}"

# Read manifest to get app versions
echo "Reading manifest to get application versions..."
APP_VERSIONS=$("{erlang_home}"/bin/erl -noshell -eval '
    {{ok, Binary}} = file:read_file("'$MANIFEST_FILE'"),
    Map = binary_to_term(Binary),
    maps:fold(fun(App, Version, Acc) ->
        io:format("~s:~s ", [App, Version]),
        Acc
    end, ok, Map),
    halt().' 2>/dev/null)

echo "Creating bundle structure..."
mkdir -p "$BUNDLE_DIR/bin"
mkdir -p "$BUNDLE_DIR/releases"

# Copy run script to bin directory
cp "$RUN_SCRIPT" "$BUNDLE_DIR/bin/run"
chmod +x "$BUNDLE_DIR/bin/run"

# Copy release files
cp "$REL_FILE" "$BUNDLE_DIR/releases/"

# Get release version from .rel file
RELEASE_VERSION=$("{erlang_home}"/bin/erl -noshell -eval '
    {{ok, [{{release, {{_, Version}}, _, _}}]}} = file:consult("'$REL_FILE'"),
    io:format("~s", [Version]),
    halt().' 2>/dev/null)

mkdir -p "$BUNDLE_DIR/releases/$RELEASE_VERSION"
cp "$BOOT_FILE" "$BUNDLE_DIR/releases/$RELEASE_VERSION/start.boot"
cp "$SCRIPT_FILE" "$BUNDLE_DIR/releases/$RELEASE_VERSION/"
cp "$REL_FILE" "$BUNDLE_DIR/releases/$RELEASE_VERSION/"

# Copy sys.config if provided
{sys_config_copy}

# Process each app - create lib/app-version structure
{process_apps}

echo "Bundle created successfully at $BUNDLE_DIR"
""".format(
        maybe_install_erlang = maybe_install_erlang(ctx),
        erlang_home = erlang_home,
        bundle_dir = bundle_dir.path,
        manifest_file = release_info.manifest_file.path,
        rel_file = release_info.rel_file.path,
        script_file = release_info.script_file.path,
        boot_file = release_info.boot_file.path,
        run_script = run_script.path,
        release_name = release_name,
        process_apps = "".join(app_processing_lines),
        sys_config_copy = """if [ -n "{sys_config}" ]; then
    echo "Copying sys.config to release..."
    cp "{sys_config}" "$BUNDLE_DIR/releases/$RELEASE_VERSION/sys.config"
    cp "{sys_config}" "$BUNDLE_DIR/sys.config"  # Also copy to root for easier access
fi""".format(sys_config = sys_config_file.path if sys_config_file else ""),
    )

    inputs = depset(
        direct = input_files,
        transitive = [runfiles.files],
    )

    ctx.actions.run_shell(
        inputs = inputs,
        outputs = [bundle_dir],
        command = script,
        mnemonic = "ErlangReleaseBundle",
        progress_message = "Creating Erlang release bundle for {}".format(release_name),
    )

    return [
        DefaultInfo(
            files = depset([bundle_dir]),
            runfiles = ctx.runfiles(files = [bundle_dir]),
        ),
    ]


erlang_release_bundle = rule(
    implementation = _impl,
    attrs = {
        "release": attr.label(
            mandatory = True,
            providers = [ErlangReleaseInfo],
            doc = "The erlang_release target to bundle",
        ),
        "sys_config": attr.label(
            doc = """Optional sys.config file generated by erlang_sys_config or elixir_sys_config rule.
                     Can accept either our SysConfigInfo provider or a rule that provides
                     the sys.config file in DefaultInfo (for Elixir compatibility).""",
        ),
        "_run_script_template": attr.label(
            default = Label("//tools:run_script.sh.tpl"),
            allow_single_file = True,
            doc = "Template for the run script",
        ),
    },
    toolchains = ["//tools:toolchain_type"],
    doc = """Create an Erlang release bundle with proper directory structure.

This rule takes an erlang_release target and creates a bundle with the
standard Erlang release directory structure:
    lib/app_name-version/ebin/
    lib/app_name-version/priv/
    releases/release_name.rel
    releases/version/start.boot
    releases/version/release_name.script
    releases/version/release_name.rel
    bin/

Example:
    erlang_release_bundle(
        name = "my_bundle",
        release = ":my_release",
    )
""",
)
