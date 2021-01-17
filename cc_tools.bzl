"""Helper functions for using the C++ Starlark API."""

load("@bazel_tools//tools/build_defs/cc:action_names.bzl", "CPP_LINK_DYNAMIC_LIBRARY_ACTION_NAME")
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

def _apply_alwayslink(ctx, linker_inputs, link_all_statically):
    cc_toolchain, feature_configuration = _cc_toolchain_info(ctx)

    # I really wish there were an easier way of doing this.
    return [
        cc_common.create_linker_input(
            owner = linker_input.owner,
            libraries = depset([
                library if (
                    (not link_all_statically and library.dynamic_library)
                    or not (library.pic_static_library or library.static_library)
                ) else cc_common.create_library_to_link(
                    actions = ctx.actions,
                    feature_configuration = feature_configuration,
                    cc_toolchain = cc_toolchain,
                    pic_static_library = library.pic_static_library,
                    static_library = library.static_library,
                    alwayslink = True,
                )
                for library in linker_input.libraries
            ]),
            user_link_flags = depset(linker_input.user_link_flags),
            additional_inputs = depset(linker_input.additional_inputs),
        ) if linker_input.libraries else linker_input
        for linker_input in linker_inputs
    ]

def module_linking_context(ctx, name, srcs, textual_hdrs, defines, copts, linkopts, compilation_contexts):
    """Creates a linking context for the given module.

    Args:
      ctx: The requesting context.
      name: The name of the library to create.
      srcs: As in cc_library.
      textual_hdrs: As in cc_library.
      defines: As in cc_library.
      copts: As in cc_library.
      linkopts: As in cc_library.
      compilation_contexts: For dependencies.

    Returns:
      The linking context for the module.
    """
    cc_toolchain, feature_configuration = _cc_toolchain_info(ctx)
    _, compilation_outputs = cc_common.compile(
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        name = name,
        srcs = srcs,
        private_hdrs = textual_hdrs,
        defines = defines,
        user_compile_flags = copts,
        compilation_contexts = compilation_contexts,
    )
    linking_context, _ = cc_common.create_linking_context_from_compilation_outputs(
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        compilation_outputs = compilation_outputs,
        name = name,
        user_link_flags = linkopts,
    )
    return linking_context

def link_so(ctx, name, link_deps_statically, linker_inputs = [], **kwargs):
    """Links the given LinkerInput objects into a shared library.

    Args:
      ctx: The requesting context.
      name: The name of the library to create.
      link_deps_statically: Whether the linker inputs should be statically
        linked into the shared library.
      linker_inputs: A sequence of LinkerInput objects to link into the library
        we're creating.
      **kwargs: Arguments to cc_common.link.

    Returns:
      The created dynamic library (a File).
    """
    cc_toolchain, feature_configuration = _cc_toolchain_info(ctx)
    linking_outputs = cc_common.link(
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        linking_contexts = [cc_common.create_linking_context(
            linker_inputs = depset(_apply_alwayslink(ctx, linker_inputs, link_deps_statically)),
        )],
        name = name,
        output_type = "dynamic_library",
        link_deps_statically = link_deps_statically,
        **kwargs
    )
    return linking_outputs.library_to_link.resolved_symlink_dynamic_library

def link_with_placeholder(ctx, output, target_label, library_linker_inputs = None):
    """Creates a shared library linked against a library that doesn't exist yet.

    This is useful for creating a module library that depends on the native deps
    library; we cannot link directly against it, as this would cause a circular
    dependency, but we can count on it to be available.

    If given linker inputs, the module library is linked with them. Otherwise,
    it is empty. It is linked against an empty placeholder, and the library at
    target_label is expected to provide any required symbols later.

    Then we set the rpath. The macOS wrapper does some magic to support rpath,
    but it does expect the library to be present at the right path. The C++ API
    provides the placeholder under _darwin_solib, which won't do, so we resort
    to invoking a command line. Something like this would work on Linux:

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
                linker_inputs = [cc_common.create_linker_input(
                    owner = ctx.label,
                    libraries = depset([library_to_link(ctx, placeholder)]),
                    user_link_flags = depset(["-Wl,-rpath,$ORIGIN/%s" % rpath]),
                )],
                link_deps_statically = False,
            ))

    Args:
      ctx: The requesting context.
      output: Where the library we're creating should be found (a File).
      target_label: The label where the actual library we're linking against
        will be present.
      library_linker_inputs: A depset of LinkerInput objects for the library
        we're creating. If not given, will create an empty library.
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

    # Compile the placeholder itself.
    placeholder = ctx.actions.declare_file(
        "%s/%s/lib%s.so" % (tmpdir, target_path, target_name),
    )
    ctx.actions.symlink(output = placeholder, target_file = link_so(
        ctx = ctx,
        name = "_%s__%s__%s__placeholder" % (tmpdir, target_path, target_name),
        # Unless we link with a dynamically-linked placeholder, macOS will
        # expect symbols to be present in the actual placeholder library, not
        # just available through it.
        link_deps_statically = False,
    ))

    # Compute the rpath we should set. If the output belongs to another
    # workspace, its short path will start with ../.
    levels_up = output.short_path.count("/") + (
        -1 if output.owner.workspace_name else 1
    )
    rpath = "../" * levels_up + target_path

    library_pic_objects = depset(transitive = [
        depset(library.pic_objects)
        for library_linker_input in library_linker_inputs.to_list()
        for library in library_linker_input.libraries
    ]).to_list() if library_linker_inputs else []

    # We invoke the linker directly (rather than through cc_common.link) so we
    # have perfect control over the paths.
    tmp_output = ctx.actions.declare_file(
        "%s/%s/%s" % (tmpdir, ctx.workspace_name, output.short_path),
    )
    linker = cc_common.get_tool_for_action(
        feature_configuration = feature_configuration,
        action_name = CPP_LINK_DYNAMIC_LIBRARY_ACTION_NAME,
    )
    link_variables = cc_common.create_link_variables(
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        library_search_directories = depset([placeholder.dirname]),
        output_file = tmp_output.path,
        is_linking_dynamic_library = True,
        user_link_flags = [
            "-l%s" % target_name,
            "-Wl,-rpath,%s/%s" % (
                "@loader_path" if cc_toolchain.cpu == "darwin" else r"\$ORIGIN",
                rpath,
            ),
        ] + [obj.path for obj in library_pic_objects],
    )
    linker_args = cc_common.get_memory_inefficient_command_line(
        feature_configuration = feature_configuration,
        action_name = CPP_LINK_DYNAMIC_LIBRARY_ACTION_NAME,
        variables = link_variables,
    )
    ctx.actions.run_shell(
        mnemonic = "CcLinkWithPlaceholder",
        progress_message = "Linking %s with placeholder for %s/lib%s.so" % (
            output.short_path,
            target_path,
            target_name,
        ),
        inputs = [placeholder] + library_pic_objects,
        outputs = [tmp_output],
        tools = cc_toolchain.all_files,
        command = " ".join([linker] + linker_args),
        use_default_shell_env = True,
    )
    ctx.actions.symlink(output = output, target_file = tmp_output)
