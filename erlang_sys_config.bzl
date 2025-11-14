"""Rules for generating Erlang sys.config files for releases."""

# Provider to pass sys.config information between rules
SysConfigInfo = provider(
    doc = "Information about a generated sys.config file",
    fields = {
        "file": "The generated sys.config File object",
        "env": "The environment (prod, dev, test)",
        "configs": "Dictionary of app_name -> config_term for debugging",
    },
)

def _erlang_sys_config_impl(ctx):
    """Implementation of erlang_sys_config rule."""

    # Determine output file name
    output_file = ctx.actions.declare_file(ctx.attr.name + ".config")

    # Build the sys.config content
    config_lines = ["["]

    if ctx.attr.config_file:
        # If a config file is provided, use it directly
        ctx.actions.run_shell(
            inputs = [ctx.file.config_file],
            outputs = [output_file],
            command = "cp {} {}".format(ctx.file.config_file.path, output_file.path),
        )
    else:
        # Build config from the configs dictionary
        config_entries = []
        for app_name, config_term in ctx.attr.configs.items():
            # Each entry should be {app_name, config_term}
            # We expect config_term to be a valid Erlang term string
            entry = "  {{{}, {}}}".format(app_name, config_term)
            config_entries.append(entry)

        config_lines.extend([",\n".join(config_entries)])
        config_lines.append("].")

        # Write the config file
        ctx.actions.write(
            output = output_file,
            content = "\n".join(config_lines),
        )

    return [
        DefaultInfo(files = depset([output_file])),
        SysConfigInfo(
            file = output_file,
            env = ctx.attr.env,
            configs = ctx.attr.configs,
        ),
    ]

erlang_sys_config = rule(
    implementation = _erlang_sys_config_impl,
    attrs = {
        "configs": attr.string_dict(
            doc = """Dictionary of application configurations.
                     Keys are application names (strings),
                     values are Erlang term strings representing the configuration.
                     Example: {"kernel": "[{logger_level, info}]", "myapp": "[{port, 8080}]"}""",
            default = {},
        ),
        "config_file": attr.label(
            doc = "An existing sys.config file to use instead of generating one",
            allow_single_file = [".config"],
        ),
        "env": attr.string(
            doc = "Environment for this configuration (prod, dev, or test)",
            default = "prod",
            values = ["prod", "dev", "test"],
        ),
    },
    doc = """Generate an Erlang sys.config file for use with releases.

    This rule creates a sys.config file that can be used with erlang_release_bundle
    to provide configuration for Erlang applications in a release.

    Example usage:
        erlang_sys_config(
            name = "prod_config",
            configs = {
                "kernel": "[{logger_level, info}]",
                "myapp": "[{port, 8080}, {workers, 10}]",
            },
            env = "prod",
        )

        # Or use an existing config file:
        erlang_sys_config(
            name = "dev_config",
            config_file = "config/sys.config",
            env = "dev",
        )
    """,
)