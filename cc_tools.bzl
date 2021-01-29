"""Helper functions for using the C++ Starlark API."""

load("@bazel_tools//tools/cpp:toolchain_utils.bzl", "find_cpp_toolchain")

def _cc_toolchain_info(ctx):
    cc_toolchain = find_cpp_toolchain(ctx)
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )
    return cc_toolchain, feature_configuration

def compile(ctx, name, srcs):
    cc_toolchain, feature_configuration = _cc_toolchain_info(ctx)
    _, compilation_outputs = cc_common.compile(
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        name = name,
        srcs = srcs,
    )
    return compilation_outputs

def link_so(ctx, name, compilation_outputs = None, linking_contexts = [], link_deps_statically = True, **kwargs):
    cc_toolchain, feature_configuration = _cc_toolchain_info(ctx)
    linking_outputs = cc_common.link(
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        compilation_outputs = compilation_outputs,
        linking_contexts = linking_contexts,
        name = name,
        output_type = "dynamic_library",
        link_deps_statically = link_deps_statically,
        **kwargs,
    )
    return linking_outputs.library_to_link.resolved_symlink_dynamic_library

def link_with_placeholder(ctx, output, target_label):
    """Creates a shared library linked against a library that doesn't yet exist.

    This is useful for creating a module library that depending on the native
    deps library; we cannot link directly against it, as this would cause a
    circular dependency, but we can count on it to be available.

    Technically, this is done by linking against an empty library and setting
    the rpath. The macOS wrapper does some magic to support rpath, but it does
    expect the library to be present at the right path. The C++ API provides
    the placeholder under _darwin_solib, which won't do. This works on Linux:

        def library_to_link(ctx, dynamic_library):
            cc_toolchain, feature_configuration = _cc_toolchain_info(ctx)
            return cc_common.create_library_to_link(
                actions = ctx.actions,
                feature_configuration = feature_configuration,
                cc_toolchain = cc_toolchain,
                dynamic_library = dynamic_library,
            )

        def link_with_placeholder(ctx, output, target_path, target_name):
            # ... setup as below ...
            ctx.actions.symlink(output = output, target_file = link_so(
                ctx = ctx,
                name = ctx.label.name,
                linking_contexts = [cc_common.create_linking_context(
                    linker_inputs = depset([cc_common.create_linker_input(
                        owner = ctx.label,
                        libraries = depset([library_to_link(ctx, placeholder)]),
                        user_link_flags = depset(["-Wl,-rpath,$ORIGIN/%s" % rpath]),
                    )]),
                )],
                link_deps_statically = False,
            ))
    """
    cc_toolchain, feature_configuration = _cc_toolchain_info(ctx)

    target_path = "/".join([
        target_label.workspace_name or ctx.workspace_name,
        target_label.package,
    ]).strip("/")
    target_name = target_label.name

    # We keep the placeholder in a subdirectory named after the label to avoid
    # conflicts between targets in the same package that link against it.
    tmpdir = "_%s" % ctx.label.name
    placeholder = ctx.actions.declare_file(
        "%s/%s/lib%s.so" % (tmpdir, target_path, target_name))
    ctx.actions.symlink(output = placeholder, target_file = link_so(
        ctx = ctx,
        name = "_%s__%s__%s" % (tmpdir, target_path, target_name),
        compilation_outputs = compile(ctx = ctx, name = "empty", srcs = []),
    ))
    tmp_output = ctx.actions.declare_file(
        "%s/%s/%s" % (tmpdir, ctx.workspace_name, output.short_path))

    # If the output belongs to another workspace, its short path starts with ../.
    levels_up = output.short_path.count("/") + (-1 if output.owner.workspace_name else 1)
    rpath = "../" * levels_up + target_path

    # We invoke the linker directly (through the compiler wrapper) so we have
    # perfect control over the paths.
    ctx.actions.run_shell(
        mnemonic = "CcLinkWithPlaceholder",
        progress_message = "Linking %s with placeholder for %s/lib%s.so" % (
            output.short_path, target_path, target_name),
        inputs = [placeholder],
        outputs = [tmp_output],
        tools = cc_toolchain.all_files,
        use_default_shell_env = True,
        command = " ".join([
            cc_toolchain.compiler_executable,
            "-shared",
            "-o", tmp_output.path,
            "-l" + target_name,
            "-L" + placeholder.dirname,
            "-Wl,-rpath,%s/%s" % (
                "@loader_path" if cc_toolchain.cpu == "darwin" else r"\$ORIGIN",
                rpath
            ),
        ]),
    )
    ctx.actions.symlink(output = output, target_file = tmp_output)
