# Building Erlang Release Bundles: A Complete Guide

This guide explains the complete process of building a deployable Erlang release bundle from source code using rules_erlang. We'll walk through each step of the pipeline, from compiling bytecode to creating a production-ready bundle.

## Overview

Building an Erlang release bundle involves three main stages:

1. **Compile bytecode** - Build your application and generate BEAM files with app metadata
2. **Generate configuration** (optional) - Create sys.config for runtime configuration
3. **Create release** - Generate OTP release files (.rel, .script, .boot)
4. **Bundle release** - Package everything into a deployable directory structure

```
Source Code
    ↓
[erlang_app]
    ↓
Bytecode + ErlangAppInfo
    ↓
[erlang_sys_config] (optional)
    ↓
Configuration Files
    ↓
[erlang_release]
    ↓
Release Files (.rel, .script, .boot)
    ↓
[erlang_release_bundle]
    ↓
Deployable Bundle
```

---

## Step 1: Building Application Bytecode with erlang_app

The first step is compiling your Erlang code into BEAM bytecode and generating the necessary application metadata using the `erlang_app` rule.

### Basic erlang_app Example

```starlark
load("@rules_erlang//:erlang_app.bzl", "erlang_app")

erlang_app(
    name = "my_app",
    app_name = "my_app",
    app_version = "1.0.0",
    app_description = "My Erlang application",
    app_module = "my_app",
)
```

### Project Structure

The `erlang_app` macro expects the standard OTP application layout:

```
my_app/
├── BUILD.bazel
├── include/
│   ├── my_app.hrl
│   └── ...
├── priv/
│   └── schema/
│       └── ...
└── src/
    ├── my_app.app.src
    ├── my_app.erl
    ├── my_app_sup.erl
    └── ...
```

### Key Attributes

- `app_name`: The name of your application (must match the module prefix)
- `app_version`: Version string for the application
- `app_description`: Human-readable description
- `app_module`: The application callback module (optional, for OTP applications)
- `extra_apps`: List of additional OTP applications this app depends on
- `deps`: Bazel dependencies (other erlang_app targets)

### Application with Dependencies

```starlark
erlang_app(
    name = "my_app",
    app_name = "my_app",
    app_version = "1.0.0",
    app_description = "My Erlang application",
    app_module = "my_app",
    extra_apps = [
        "crypto",
        "ssl",
        "inets",
    ],
    deps = [
        "//lib/my_dependency:erlang_app",
    ],
)
```

### What erlang_app Produces

- Compiled BEAM files in an `ebin/` directory
- Generated `.app` file with application metadata
- `ErlangAppInfo` provider containing all app metadata and dependencies

The `ErlangAppInfo` provider is used by downstream rules (like `erlang_release`) to understand your application's structure and dependencies.

---

## Step 2: Generating Configuration with erlang_sys_config

System configuration provides runtime settings for your application and OTP libraries using Erlang's standard sys.config format.

### What is sys.config?

The `sys.config` file is an Erlang term file that configures application parameters. It has this format:

```erlang
[
  {kernel, [
    {logger_level, info}
  ]},
  {my_app, [
    {port, 8080},
    {workers, 10}
  ]}
].
```

### Creating sys.config with erlang_sys_config

```starlark
load("@rules_erlang//:erlang_sys_config.bzl", "erlang_sys_config")

erlang_sys_config(
    name = "prod_config",
    configs = {
        "kernel": "[{logger_level, info}]",
        "my_app": "[{port, 8080}, {workers, 10}]",
    },
    env = "prod",
)
```

### Key Attributes

- `configs`: Dictionary mapping application names to their configuration terms (as strings)
- `env`: Environment name ("prod", "dev", or "test")
- `config_file`: Alternatively, provide an existing sys.config file instead of generating one

### Using an Existing Config File

If you already have a sys.config file:

```starlark
erlang_sys_config(
    name = "prod_config",
    config_file = "config/sys.config",
    env = "prod",
)
```

### Environment-Specific Configurations

Create different configurations for different environments:

```starlark
# Development configuration
erlang_sys_config(
    name = "dev_config",
    configs = {
        "kernel": "[{logger_level, debug}]",
        "my_app": "[{port, 8081}, {workers, 2}, {debug_mode, true}]",
    },
    env = "dev",
)

# Production configuration
erlang_sys_config(
    name = "prod_config",
    configs = {
        "kernel": "[{logger_level, info}]",
        "my_app": "[{port, 8080}, {workers, 10}]",
    },
    env = "prod",
)

# Test configuration
erlang_sys_config(
    name = "test_config",
    configs = {
        "kernel": "[{logger_level, warning}]",
        "my_app": "[{port, 9999}, {workers, 1}, {test_mode, true}]",
    },
    env = "test",
)
```

### What erlang_sys_config Produces

- A `.config` file in Erlang term format
- `SysConfigInfo` provider for use by `erlang_release_bundle`

---

## Step 3: Creating the Release with erlang_release

The `erlang_release` rule generates the OTP release specification and boot files using SASL's `systools:make_script/2`.

### How erlang_release Works

Under the hood, `erlang_release`:

1. Collects all dependencies transitively from your app using `flat_deps()`
2. Extracts version information from each app's `.app` file
3. Runs the `build_release` escript tool which calls `systools:make_script/2`
4. Generates `.rel`, `.script`, and `.boot` files
5. Creates a manifest file mapping application names to versions

### Basic Release

```starlark
load("@rules_erlang//:erlang_release.bzl", "erlang_release")

erlang_release(
    name = "my_release",
    app = ":my_app",
)
```

This creates a release with the same name as your application.

### Release with Custom Name and Version

```starlark
erlang_release(
    name = "my_release",
    app = ":my_app",
    release_name = "production",
    release_version = "1.0.0",
)
```

### Release with Extra OTP Applications

Sometimes you need OTP applications that aren't direct dependencies but are required at runtime:

```starlark
erlang_release(
    name = "my_release",
    app = ":my_app",
    release_name = "my_app_prod",
    release_version = "1.0.0",
    extra_apps = [
        "compiler",  # For runtime code compilation
        "crypto",    # Cryptographic operations
        "ssl",       # TLS/SSL support
        "inets",     # HTTP client/server
        "runtime_tools",  # For profiling and debugging
    ],
)
```

### Key Attributes

- `app`: Your application target (providing `ErlangAppInfo`)
- `release_name`: Name for the release (defaults to app name)
- `release_version`: Version string (defaults to "1.0.0")
- `app_version`: Override the application version (defaults to version from .app file)
- `extra_apps`: Additional OTP applications to include

### Understanding extra_apps

The `extra_apps` attribute is crucial for including OTP standard library applications that your code uses but aren't explicit dependencies. Common examples:

- `compiler` - If you use `c:c/1` or similar for dynamic compilation
- `crypto` - For cryptographic functions
- `ssl` - For TLS/SSL connections
- `inets` - For HTTP client (httpc) or server (httpd)
- `mnesia` - For the Mnesia database
- `runtime_tools` - For debugging tools like `observer`
- `tools` - For additional debugging and profiling

### What erlang_release Produces

- `{release_name}.rel` - Release specification file listing all applications and versions
- `{release_name}.script` - Human-readable boot script
- `{release_name}.boot` - Binary boot file used by the Erlang VM
- `{release_name}.manifest` - EETF-encoded map of application names to versions
- `ErlangReleaseInfo` provider for bundling

### Important Note: No sys.config Here

**The `erlang_release` rule does not accept a sys.config**. Configuration is added later in the bundling step. This design allows you to create one release and bundle it with different configurations for different environments.

---

## Step 4: Creating the Bundle with erlang_release_bundle

The `erlang_release_bundle` rule packages everything into a complete, deployable OTP release structure.

### What erlang_release_bundle Does

1. Creates the standard OTP directory structure
2. Copies all BEAM files into `lib/{app}-{version}/ebin/`
3. Copies priv directories into `lib/{app}-{version}/priv/`
4. Copies release files into `releases/` and `releases/{version}/`
5. Copies sys.config (if provided) into `releases/{version}/`
6. Generates a startup script in `bin/run`

### Basic Bundle

```starlark
load("@rules_erlang//:erlang_release_bundle.bzl", "erlang_release_bundle")

erlang_release_bundle(
    name = "my_bundle",
    release = ":my_release",
)
```

### Bundle with Configuration

This is where you add the sys.config:

```starlark
erlang_release_bundle(
    name = "my_prod_bundle",
    release = ":my_release",
    sys_config = ":prod_config",
)
```

### Multiple Bundles from One Release

A powerful pattern is creating one release and multiple bundles with different configurations:

```starlark
# Create the release once
erlang_release(
    name = "my_release",
    app = ":my_app",
    release_version = "1.0.0",
)

# Create different sys.config files
erlang_sys_config(
    name = "dev_config",
    configs = {
        "kernel": "[{logger_level, debug}]",
        "my_app": "[{env, dev}]",
    },
    env = "dev",
)

erlang_sys_config(
    name = "prod_config",
    configs = {
        "kernel": "[{logger_level, info}]",
        "my_app": "[{env, prod}]",
    },
    env = "prod",
)

# Bundle for development
erlang_release_bundle(
    name = "dev_bundle",
    release = ":my_release",
    sys_config = ":dev_config",
)

# Bundle for production
erlang_release_bundle(
    name = "prod_bundle",
    release = ":my_release",
    sys_config = ":prod_config",
)
```

### Key Attributes

- `release`: The `erlang_release` target to bundle (mandatory)
- `sys_config`: The `erlang_sys_config` target providing configuration (optional)

### Bundle Directory Structure

The generated bundle has this structure:

```
my_bundle/
├── bin/
│   └── run                    # Startup script
├── lib/
│   ├── my_app-1.0.0/
│   │   ├── ebin/
│   │   │   ├── my_app.beam
│   │   │   ├── my_app_sup.beam
│   │   │   └── my_app.app
│   │   └── priv/
│   │       └── schema/
│   ├── kernel-8.5/
│   │   └── ebin/
│   ├── stdlib-4.3/
│   │   └── ebin/
│   └── sasl-4.2/
│       └── ebin/
└── releases/
    ├── production.rel
    └── 1.0.0/
        ├── sys.config         # If sys_config was provided
        ├── start.boot
        ├── production.script
        └── production.rel
```

### Running the Bundle

After building, you can run your release:

```bash
# Build the bundle
bazel build //:my_bundle

# The bundle is in bazel-bin
ls bazel-bin/my_bundle/

# Run it (you'll need to extract/copy it first in most cases)
cp -r bazel-bin/my_bundle /opt/my_app

# Start the release
/opt/my_app/bin/run
```

The run script accepts various arguments depending on the template used. Common patterns include:

```bash
# Start with a console
erl -boot /opt/my_app/releases/1.0.0/start

# Start as a daemon
erl -boot /opt/my_app/releases/1.0.0/start -detached -noinput
```

---

## Complete Example

Here's a complete BUILD.bazel file showing all the pieces together:

```starlark
load("@rules_erlang//:erlang_app.bzl", "erlang_app")
load("@rules_erlang//:erlang_release.bzl", "erlang_release")
load("@rules_erlang//:erlang_release_bundle.bzl", "erlang_release_bundle")
load("@rules_erlang//:erlang_sys_config.bzl", "erlang_sys_config")

# Step 1: Build the application
erlang_app(
    name = "my_app",
    app_name = "my_app",
    app_version = "1.0.0",
    app_description = "My production application",
    app_module = "my_app",
    extra_apps = [
        "crypto",
        "ssl",
    ],
)

# Step 2: Generate configurations for different environments
erlang_sys_config(
    name = "dev_config",
    configs = {
        "kernel": "[{logger_level, debug}]",
        "my_app": "[{port, 8081}, {workers, 2}, {debug_mode, true}]",
    },
    env = "dev",
)

erlang_sys_config(
    name = "prod_config",
    configs = {
        "kernel": "[{logger_level, info}]",
        "my_app": "[{port, 8080}, {workers, 10}]",
    },
    env = "prod",
)

# Step 3: Create the release
erlang_release(
    name = "my_release",
    app = ":my_app",
    release_name = "my_app_prod",
    release_version = "1.0.0",
    extra_apps = [
        "crypto",
        "ssl",
        "inets",
        "runtime_tools",
    ],
)

# Step 4: Create bundles for different environments
erlang_release_bundle(
    name = "dev_bundle",
    release = ":my_release",
    sys_config = ":dev_config",
)

erlang_release_bundle(
    name = "prod_bundle",
    release = ":my_release",
    sys_config = ":prod_config",
)
```

Build the bundles:

```bash
# Development bundle
bazel build //:dev_bundle

# Production bundle
bazel build //:prod_bundle
```

---

## Minimal Example (No Configuration)

If you want a minimal release without sys.config:

```starlark
load("@rules_erlang//:erlang_app.bzl", "erlang_app")
load("@rules_erlang//:erlang_release.bzl", "erlang_release")
load("@rules_erlang//:erlang_release_bundle.bzl", "erlang_release_bundle")

erlang_app(
    name = "simple_app",
    app_name = "simple_app",
    app_version = "1.0.0",
)

erlang_release(
    name = "simple_release",
    app = ":simple_app",
)

erlang_release_bundle(
    name = "simple_bundle",
    release = ":simple_release",
)
```

Build it:

```bash
bazel build //:simple_bundle
```

---

## Understanding the Providers

Each step produces providers that carry information to the next stage:

### ErlangAppInfo

Produced by: `erlang_app`

Contains:
- `app_name`: Application name
- `beam`: List of BEAM files and .app file
- `priv`: Private resource files
- `deps`: List of dependencies (also providing ErlangAppInfo)
- Application metadata (version, description, modules, etc.)

Used by `erlang_release` to collect all applications and their dependencies.

### SysConfigInfo

Produced by: `erlang_sys_config`

Contains:
- `file`: The generated sys.config file
- `env`: Environment name (prod/dev/test)
- `configs`: Dictionary of configurations for debugging

Used by `erlang_release_bundle` to include configuration in the bundle.

### ErlangReleaseInfo

Produced by: `erlang_release`

Contains:
- `rel_file`: Path to the .rel file
- `script_file`: Path to the .script file
- `boot_file`: Path to the .boot file
- `manifest_file`: Path to the manifest file
- `app_name`: Name of the main application
- `app_info`: The ErlangAppInfo of the main app
- `release_name`: Name of the release
- `release_version`: Version of the release

Used by `erlang_release_bundle` to create the complete bundle structure.

---

## Comparing with Elixir Releases

If you're coming from Elixir/Mix releases, here are the key differences:

| Feature | rules_erlang | rules_mix (Elixir) |
|---------|--------------|-------------------|
| Application rule | `erlang_app` | `mix_library` or `elixir_app` |
| Protocol consolidation | N/A (Erlang only) | `protocol_consolidation` |
| Boot script processing | Direct from systools | Post-processed for Config.Provider |
| Configuration | sys.config only | sys.config + runtime.exs |
| Release rule | `erlang_release` | `elixir_release` (wraps erlang_release) |
| Bundle rule | `erlang_release_bundle` | `elixir_release_bundle` |

The rules_erlang approach is simpler and more direct, as it doesn't need to handle Elixir-specific features like protocols or runtime configuration with Config.Provider.

---

## Real-World Examples

### Example 1: Web Server Application

```starlark
erlang_app(
    name = "web_server",
    app_name = "web_server",
    app_version = "2.1.0",
    app_description = "HTTP server application",
    app_module = "web_server_app",
    extra_apps = [
        "inets",  # For HTTP server
        "ssl",    # For HTTPS
    ],
)

erlang_sys_config(
    name = "web_config",
    configs = {
        "kernel": "[{logger_level, info}]",
        "inets": """[
            {services, [
                {httpd, [
                    {port, 8080},
                    {server_name, "web_server"},
                    {server_root, "/opt/web_server"},
                    {document_root, "/opt/web_server/www"}
                ]}
            ]}
        ]""",
        "web_server": "[{max_connections, 1000}]",
    },
    env = "prod",
)

erlang_release(
    name = "web_release",
    app = ":web_server",
    release_name = "web_server",
    release_version = "2.1.0",
    extra_apps = ["inets", "ssl", "crypto"],
)

erlang_release_bundle(
    name = "web_bundle",
    release = ":web_release",
    sys_config = ":web_config",
)
```

### Example 2: Database Application with Mnesia

```starlark
erlang_app(
    name = "db_app",
    app_name = "db_app",
    app_version = "1.5.0",
    app_description = "Database application with Mnesia",
    app_module = "db_app",
    extra_apps = ["mnesia"],
)

erlang_sys_config(
    name = "db_config",
    configs = {
        "kernel": "[{logger_level, info}]",
        "mnesia": """[
            {dir, "/var/lib/db_app/mnesia"},
            {dump_log_write_threshold, 10000}
        ]""",
        "db_app": "[{backup_interval, 3600}]",
    },
    env = "prod",
)

erlang_release(
    name = "db_release",
    app = ":db_app",
    release_name = "db_app",
    release_version = "1.5.0",
    extra_apps = ["mnesia", "crypto"],
)

erlang_release_bundle(
    name = "db_bundle",
    release = ":db_release",
    sys_config = ":db_config",
)
```

---

## Troubleshooting

### "Application X not found in release"

Make sure the application is either:
1. A dependency in your `erlang_app` `deps` attribute, or
2. Listed in `extra_apps` in your `erlang_release`

```starlark
erlang_release(
    name = "my_release",
    app = ":my_app",
    extra_apps = ["crypto"],  # Add missing OTP app here
)
```

### "Could not find sys.config file"

Check that you're passing `sys_config` to `erlang_release_bundle`, not `erlang_release`:

```starlark
# WRONG - erlang_release doesn't accept sys_config
erlang_release(
    name = "my_release",
    app = ":my_app",
    sys_config = ":prod_config",  # This will fail!
)

# CORRECT - use sys_config with erlang_release_bundle
erlang_release_bundle(
    name = "my_bundle",
    release = ":my_release",
    sys_config = ":prod_config",  # This works!
)
```

### Release won't start

Try these steps:

1. **Check your .app.src file** - Make sure all required applications are listed:
   ```erlang
   {application, my_app, [
       {applications, [kernel, stdlib, sasl, crypto]}
   ]}.
   ```

2. **Verify extra_apps** - Ensure all required OTP apps are in `extra_apps`:
   ```starlark
   erlang_release(
       name = "my_release",
       app = ":my_app",
       extra_apps = ["crypto", "ssl"],
   )
   ```

3. **Check sys.config syntax** - Make sure your configuration is valid Erlang terms:
   ```starlark
   erlang_sys_config(
       name = "config",
       configs = {
           "my_app": "[{port, 8080}]",  # Note: valid Erlang list syntax
       },
   )
   ```

4. **Test manually** - Try starting with erl to see errors:
   ```bash
   cd bazel-bin/my_bundle
   erl -boot releases/1.0.0/start -config releases/1.0.0/sys
   ```

### "Duplicate application" errors

This usually means an application appears multiple times in the dependency tree with different versions. Check:

1. Your dependency graph for conflicts
2. That you're not listing the same app in both `deps` and `extra_apps`

### Bundle directory is empty or missing files

Verify that:
1. You built the bundle target, not the release target
2. The bundle target is in `bazel-bin/`, not `bazel-out/`
3. All dependencies are correctly specified

---

## Advanced Topics

### Custom Build Release Tool

The `erlang_release` rule uses the `//tools/build_release` escript. You can examine or customize this if needed for advanced scenarios.

### Boot Script Customization

The boot script (.script and .boot files) can be inspected and modified if needed. They're generated by `systools:make_script/2` from SASL.

To view the boot script:
```bash
cat bazel-bin/my_release/my_release.script
```

### Using with Docker

To package a release in a Docker container:

```dockerfile
FROM erlang:26-alpine

COPY bazel-bin/my_bundle /opt/my_app

CMD ["/opt/my_app/bin/run"]
```

---

## Next Steps

- Examine the [example_app](../example_app/) for a working example
- Look at [simple_release_test](../simple_release_test/) for test examples
- Check [test_sys_config](../test_sys_config/) for sys.config examples
- See [tools/RUN_SCRIPT_CONSIDERATIONS.md](../tools/RUN_SCRIPT_CONSIDERATIONS.md) for startup script details

---

## Summary

Building an Erlang release bundle is a straightforward process:

1. **`erlang_app`** - Compile source → bytecode + ErlangAppInfo
2. **`erlang_sys_config`** (optional) - Generate config → sys.config + SysConfigInfo
3. **`erlang_release`** - Create OTP release → .rel/.script/.boot files + ErlangReleaseInfo
4. **`erlang_release_bundle`** - Package everything → deployable bundle directory

The key insight is that **sys.config is added at bundle time**, not release time. This allows you to create one release and bundle it multiple times with different configurations for different environments (dev, test, prod).
