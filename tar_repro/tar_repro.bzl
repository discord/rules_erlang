"""A test that the bsdtar pipeline of private/hermetic_tar.bzl is
reproducible, and that it still agrees with the GNU tar command it replaced.

Why a rule rather than an sh_test with a checked-in script? The script has to
hold the exact pipeline the producer rules run, or it protects nothing. This
rule builds the script from the same Starlark strings, so the two cannot
drift. A checked-in fixture would not work either: Bazel resolves a source
symlink on its way into the runfiles tree, and the bin/epmd symlink is one of
the four shapes under test, so the script builds the fixture itself.
"""

load(
    "//private:erlang_build.bzl",
    "RELEASE_TAR_EXCLUDES",
)
load(
    "//private:hermetic_tar.bzl",
    "TAR_TOOLCHAIN_TYPE",
    "archive_cmds",
    "bsdtar_setup",
    "mtree_cmds",
)

def _tar_repro_test_impl(ctx):
    tar_toolchain = ctx.toolchains[TAR_TOOLCHAIN_TYPE]
    bsdtar = tar_toolchain.tarinfo.binary

    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._template,
        output = script,
        is_executable = True,
        substitutions = {
            # short_path reaches an external file as ../<repo>/..., which the
            # kernel resolves against the runfiles directory the test runs in.
            "%{BSDTAR_SETUP}": bsdtar_setup(tar_toolchain, bsdtar.short_path),
            "%{MTREE_CMDS}": mtree_cmds(
                "-h " + RELEASE_TAR_EXCLUDES + " .",
                "$MTREE",
            ),
            "%{ARCHIVE_CMDS}": archive_cmds("$MTREE"),
            "%{EXCLUDES}": RELEASE_TAR_EXCLUDES,
        },
    )

    return [DefaultInfo(
        executable = script,
        runfiles = ctx.runfiles(transitive_files = tar_toolchain.default.files),
    )]

tar_repro_test = rule(
    implementation = _tar_repro_test_impl,
    attrs = {
        "_template": attr.label(
            default = Label("//tar_repro:tar_repro_test.sh.tpl"),
            allow_single_file = True,
        ),
    },
    test = True,
    toolchains = [TAR_TOOLCHAIN_TYPE],
)
