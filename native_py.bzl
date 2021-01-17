"""Rules for handling native dependencies for Python targets.

Provides four rules:
- py_library_deps: tracks the transitive dependencies of a py_* rule through
  an aspect, and statically links all the native dependencies together into a
  shared object.
- py_native_module: provides the linking context of a cc_library so it can be
  linked into the native deps library and a PyInfo for inclusion as a Python
  dependency. Through an aspect, provides an empty shared object that is
  dynamically linked to the native deps library, which is assumed to be present
  at a known location.
- nativedeps: meant to be instantiated once (by this library), it provides an
  empty shared object that is dynamically linked to the native deps library.
  It uses a transition to adjust the location of the real native deps library,
  so py_native_modules don't have to.
- configure_nativedeps: exists mostly to just pass the py_library_deps target on
  to the global nativedeps target via the transition, and to provide back the
  configured nativedeps library. It wouldn't be necessary if it were possible to
  pass in the current target through a transition. An alternative would be
  replacing the actual py_binary/py_test with a wrapper, but to do this right,
  we may have to expose providers properly, have duplicate rules for setting the
  executable/test properties right, and make a copy of the executable - which is
  annoying both if we keep it and if we prune it from the runfiles. Using three
  targets for a toplevel Python target is certainly messier, but it feels safer.

Linking against empty placeholders, and then providing the real libraries
manually, allows us to avoid transitions for all but one shared object (which is
empty itself) and save some double work.

Note that since we're using transitions, py_binaries with native dependencies
should be passed to genrules as exec_tools (rather than tools).
"""

load(":cc_tools.bzl", "link_so", "link_with_placeholder", "module_linking_context")

NATIVEDEPS_TARGET = Label("@rules_native_python//:nativedeps")
TEST_NATIVEDEPS_TARGET = Label("@rules_native_python//:test_nativedeps")
ACTUAL_NATIVEDEPS_SETTING = "@rules_native_python//:actual_nativedeps"
ACTUAL_NATIVEDEPS_DEFAULT = ""

PyNativeDepsetInfo = provider(
    "Linker inputs and runfiles for transitive dependencies of native Python modules.",
    fields = [
        "runfiles",
        "deps_cc_info",
    ],
)

_ToplevelBinaryInfo = provider(
    "Used to propagate the toplevel binary target (py_binary/py_test) to the nativedeps library.",
    fields = ["label"],
)

def _toplevel_binary_impl(ctx):
    return [_ToplevelBinaryInfo(label = str(ctx.build_setting_value))]

toplevel_binary = rule(
    implementation = _toplevel_binary_impl,
    build_setting = config.string(flag = False),
)

def _import(ctx, import_):
    package = (ctx.label.workspace_name or ctx.workspace_name) + "/" + ctx.label.package
    if import_ == "." or not import_:
        return package
    else:
        return package + "/" + import_

def _py_native_module_impl(ctx):
    deps_cc_info = cc_common.merge_cc_infos(cc_infos = [
        dep[CcInfo]
        for dep in ctx.attr.deps
    ])

    srcs, hdrs = [], list(ctx.files.textual_hdrs)
    for src in ctx.files.srcs:
        if src.extension in ("cc", "cpp", "c"):
            srcs.append(src)
        else:
            hdrs.append(src)
    linking_context = module_linking_context(
        ctx,
        ctx.label.name,
        srcs,
        hdrs,
        [
            " ".join(ctx.tokenize(ctx.expand_location(ctx.expand_make_variables("defines", d, {}))))
            for d in ctx.attr.defines
        ],
        ctx.attr.copts,
        ctx.attr.linkopts,
        [deps_cc_info.compilation_context],
    )

    module = ctx.actions.declare_file(ctx.label.name + ".so")
    link_with_placeholder(
        ctx = ctx,
        output = module,
        target_label = TEST_NATIVEDEPS_TARGET if ctx.attr.testonly else NATIVEDEPS_TARGET,
        library_linker_inputs = linking_context.linker_inputs,
    )

    return [
        PyNativeDepsetInfo(
            runfiles = ctx.runfiles(files = [module], collect_default = True).files,
            deps_cc_info = deps_cc_info if ctx.attr.deps else None,
        ),
        PyInfo(
            transitive_sources = depset(),
            imports = depset([_import(ctx, i) for i in ctx.attr.imports]),
        ),
    ]

py_native_module = rule(
    implementation = _py_native_module_impl,
    fragments = ["cpp"],
    attrs = {
        "copts": attr.string_list(),
        "data": attr.label_list(allow_files = True),
        "defines": attr.string_list(),
        "deps": attr.label_list(providers = [CcInfo]),
        "imports": attr.string_list(),
        "linkopts": attr.string_list(),
        "srcs": attr.label_list(allow_files = [".cc", ".cpp", ".c", ".h", ".hpp", ".inc", ".inl"]),
        "textual_hdrs": attr.label_list(allow_files = [".cc", ".cpp", ".c", ".h", ".hpp", ".inc", ".inl"]),
        "_cc_toolchain": attr.label(default = "@bazel_tools//tools/cpp:current_cc_toolchain"),
    },
)

def _nativedeps_impl(ctx):
    if ctx.attr._actual[_ToplevelBinaryInfo].label:
        target_label = Label(ctx.attr._actual[_ToplevelBinaryInfo].label)
        module = ctx.actions.declare_file("lib" + ctx.attr._library_name + ".so")
        link_with_placeholder(ctx = ctx, output = module, target_label = target_label)
        runfiles = ctx.runfiles([module])
        return [DefaultInfo(runfiles = runfiles)]
    return []

nativedeps = rule(
    implementation = _nativedeps_impl,
    fragments = ["cpp"],
    attrs = {
        "_actual": attr.label(default = ACTUAL_NATIVEDEPS_SETTING),
        "_cc_toolchain": attr.label(default = "@bazel_tools//tools/cpp:current_cc_toolchain"),
        "_library_name": attr.string(default = "nativedeps"),
    },
)

def _merge_py_native_depsets(py_native_depset_infos):
    deps_cc_infos = [
        dep.deps_cc_info
        for dep in py_native_depset_infos
        if dep.deps_cc_info
    ]
    return PyNativeDepsetInfo(
        runfiles = depset(
            transitive = [
                dep.runfiles
                for dep in py_native_depset_infos
            ],
        ),
        deps_cc_info = cc_common.merge_cc_infos(
            cc_infos = deps_cc_infos,
        ) if deps_cc_infos else None,
    )

def _python_module_placeholder_aspect_impl(target, ctx):
    if PyNativeDepsetInfo in target:
        return []
    else:
        return _merge_py_native_depsets([
            dep[PyNativeDepsetInfo]
            for dep in getattr(ctx.rule.attr, "deps", []) + getattr(ctx.rule.attr, "data", [])
            if PyNativeDepsetInfo in dep
        ])

python_module_placeholder_aspect = aspect(
    implementation = _python_module_placeholder_aspect_impl,
    fragments = ["cpp"],
    attr_aspects = ["data", "deps"],
    attrs = {
        "_cc_toolchain": attr.label(default = "@bazel_tools//tools/cpp:current_cc_toolchain"),
    },
)

def _propagate_actual_impl(_, attr):
    return {ACTUAL_NATIVEDEPS_SETTING: str(attr.deps[0])}

_propagate_actual = transition(
    implementation = _propagate_actual_impl,
    inputs = [],
    outputs = [ACTUAL_NATIVEDEPS_SETTING],
)

def _configure_nativedeps_impl(ctx):
    if len(ctx.attr.deps) != 1:
        fail()
    runfiles = ctx.attr.deps[0][DefaultInfo].default_runfiles
    if PyNativeDepsetInfo in ctx.attr.deps[0] and ctx.attr.deps[0][PyNativeDepsetInfo].deps_cc_info:
        runfiles = runfiles.merge(ctx.attr._nativedeps[0][DefaultInfo].default_runfiles)
    return [
        DefaultInfo(runfiles = runfiles),
        ctx.attr.deps[0][PyInfo],
    ]

def _make_configure_nativedeps_rule(nativedeps_target):
    return rule(
        implementation = _configure_nativedeps_impl,
        attrs = {
            "deps": attr.label_list(),
            "_nativedeps": attr.label(default = nativedeps_target, cfg = _propagate_actual),
            "_whitelist_function_transition": attr.label(
                default = "@bazel_tools//tools/whitelists/function_transition_whitelist",
            ),
        },
    )

configure_nativedeps = _make_configure_nativedeps_rule(NATIVEDEPS_TARGET)
configure_test_nativedeps = _make_configure_nativedeps_rule(TEST_NATIVEDEPS_TARGET)

def _py_library_deps_impl(ctx):
    runfiles = list(ctx.files.data)

    native_deps_info = _merge_py_native_depsets([
        dep[PyNativeDepsetInfo]
        for dep in ctx.attr.deps + ctx.attr.data
        if PyNativeDepsetInfo in dep
    ])

    # This is just a safeguard - errors should be caught in the deps py_library.
    if any([PyRuntimeInfo in dep for dep in ctx.attr.deps]):
        fail("%s has py_binary dependencies; this is an error." % ctx.label)

    runfiles_from_deps_and_data = ctx.runfiles(
        transitive_files = depset(transitive = [
            depset([
                f
                for f in dep[DefaultInfo].default_runfiles.files.to_list()
                if not (f.owner.name.startswith("_") and f.owner.name.endswith("_deps")) and f.owner not in (NATIVEDEPS_TARGET, TEST_NATIVEDEPS_TARGET)
            ])
            for dep in ctx.attr.deps + ctx.attr.data
        ] + [native_deps_info.runfiles]),
    )

    if native_deps_info.deps_cc_info:
        linker_inputs = native_deps_info.deps_cc_info.linking_context.linker_inputs.to_list()
        nativedeps_lib = link_so(
            ctx = ctx,
            name = ctx.label.name,
            linker_inputs = linker_inputs,
            stamp = ctx.attr.stamp,
            link_deps_statically = ctx.attr.linkstatic,
        )

        all_dynamic_libs = []
        for linker_input in linker_inputs:
            for library in linker_input.libraries:
                # If we have a dynamic library, provide it in runfiles unless
                # we have a static library and are in linkstatic mode. This is
                # the case for, e.g., cc_import targets.
                # TODO: Should we also provide library.interface_library if set?
                if library.dynamic_library and not (ctx.attr.linkstatic and library.pic_static_library):
                    all_dynamic_libs.append(library.dynamic_library)

        runfiles.append(nativedeps_lib)
        runfiles.extend(all_dynamic_libs)

    return [
        DefaultInfo(runfiles = ctx.runfiles(runfiles).merge(runfiles_from_deps_and_data)),
        PyInfo(
            transitive_sources = depset(order = "postorder", transitive = [
                dep[PyInfo].transitive_sources
                for dep in ctx.attr.deps
            ]),
            imports = depset(transitive = [dep[PyInfo].imports for dep in ctx.attr.deps]),
        ),
        native_deps_info,
    ]

py_library_deps = rule(
    implementation = _py_library_deps_impl,
    fragments = ["cpp"],
    attrs = {
        "data": attr.label_list(
            allow_files = True,
            aspects = [python_module_placeholder_aspect],
        ),
        "deps": attr.label_list(
            providers = [PyInfo],
            aspects = [python_module_placeholder_aspect],
        ),
        "linkstatic": attr.bool(),
        "stamp": attr.int(default = -1),
        "_cc_toolchain": attr.label(default = "@bazel_tools//tools/cpp:current_cc_toolchain"),
    },
)
