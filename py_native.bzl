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

load(":cc_tools.bzl", "link_so", "link_with_placeholder")

NATIVEDEPS_TARGET = Label("@rules_native_python//:nativedeps")
ACTUAL_NATIVEDEPS_SETTING = "@rules_native_python//:actual_nativedeps"

PyNativeModule = provider(fields = ["runfiles", "deps_cc_info", "srcs", "deps"])
PyNativeDepset = provider(fields = ["runfiles", "cc_infos", "deps"])

def _merge_runfiles(runfiles, runfiles_list):
    for r in runfiles_list:
        runfiles = runfiles.merge(r)
    return runfiles

def _py_native_module_impl(ctx):
    return [
        PyNativeModule(
            runfiles = ctx.attr.deps_library[DefaultInfo].default_runfiles,
            deps_cc_info = ctx.attr.deps_library[CcInfo],
            srcs = depset(transitive = [src.files for src in ctx.attr.srcs]).to_list(),
            deps = ctx.attr.deps,
        ),
        # Allow Python targets to depend on this.
        PyInfo(transitive_sources = depset()),
    ]

py_native_module = rule(
    implementation = _py_native_module_impl,
    fragments = ["cpp"],
    attrs = {
        "deps_library": attr.label(),
        "srcs": attr.label_list(allow_files = True),
        "deps": attr.label_list(providers = [CcInfo]),
        "_cc_toolchain": attr.label(default = "@bazel_tools//tools/cpp:current_cc_toolchain"),
    },
)

def _nativedeps_impl(ctx):
    target_label = ctx.attr._actual.label
    module = ctx.actions.declare_file("lib" + ctx.label.name + ".so")
    link_with_placeholder(ctx = ctx, output = module, target_label = target_label)
    runfiles = ctx.runfiles([module])
    return [DefaultInfo(runfiles = runfiles)]

nativedeps = rule(
    implementation = _nativedeps_impl,
    fragments = ["cpp"],
    attrs = {
        "_cc_toolchain": attr.label(default = "@bazel_tools//tools/cpp:current_cc_toolchain"),
        "_actual": attr.label(default = ACTUAL_NATIVEDEPS_SETTING),
    },
)

def _python_module_placeholder_aspect_impl(target, ctx):
    if PyNativeModule in target:
        module = ctx.actions.declare_file(target.label.name + ".so")
        link_with_placeholder(
            ctx = ctx,
            output = module,
            target_label = NATIVEDEPS_TARGET,
            library_srcs = target[PyNativeModule].srcs,
            cc_info = target[PyNativeModule].deps_cc_info,
        )
        return [
            PyNativeDepset(
                runfiles = ctx.runfiles([module]).merge(target[PyNativeModule].runfiles),
                cc_infos = depset([target[PyNativeModule].deps_cc_info]),
                deps = depset(target[PyNativeModule].deps),
            ),
        ]
    else:
        return [
            PyNativeDepset(
                runfiles = _merge_runfiles(ctx.runfiles(), [
                    dep[PyNativeDepset].runfiles for dep in ctx.rule.attr.deps
                ]),
                cc_infos = depset(transitive = [
                    dep[PyNativeDepset].cc_infos for dep in ctx.rule.attr.deps
                ]),
                deps = depset(transitive = [
                    dep[PyNativeDepset].deps for dep in ctx.rule.attr.deps
                ]),
            ),
        ]

python_module_placeholder_aspect = aspect(
    implementation = _python_module_placeholder_aspect_impl,
    fragments = ["cpp"],
    attr_aspects = ["deps"],
    attrs = {
        "_cc_toolchain": attr.label(default = "@bazel_tools//tools/cpp:current_cc_toolchain"),
    },
)

def _propagate_actual_impl(settings, attr):
    return {ACTUAL_NATIVEDEPS_SETTING: attr.actual}

_propagate_actual = transition(
    implementation = _propagate_actual_impl,
    inputs = [],
    outputs = [ACTUAL_NATIVEDEPS_SETTING],
)

def _configure_nativedeps_impl(ctx):
    return [DefaultInfo(runfiles = ctx.attr._nativedeps[0][DefaultInfo].default_runfiles)]

configure_nativedeps = rule(
    implementation = _configure_nativedeps_impl,
    attrs = {
        "actual": attr.label(),
        "_nativedeps": attr.label(default = NATIVEDEPS_TARGET, cfg = _propagate_actual),
        "_whitelist_function_transition": attr.label(
            default = "@bazel_tools//tools/whitelists/function_transition_whitelist",
        ),
    },
)

def _py_toplevel_target_impl(ctx):
    cc_infos = depset(transitive = [
        dep[PyNativeDepset].cc_infos for dep in ctx.attr.deps
    ])
    cc_info = cc_common.merge_cc_infos(cc_infos = cc_infos.to_list())

    # Only force-alwayslink those libraries that are direct dependencies of
    # native modules.
    direct_deps = [target.label for target in depset(transitive = [
        dep[PyNativeDepset].deps for dep in ctx.attr.deps
    ]).to_list()]
    direct_linking_contexts, indirect_linking_contexts = [], []
    for linker_inputs in cc_info.linking_context.linker_inputs.to_list():
        if linker_inputs.owner in direct_deps:
            direct_linking_contexts.append(linker_inputs)
        else:
            indirect_linking_contexts.append(linker_inputs)

    nativedeps_lib = link_so(
        ctx = ctx,
        name = ctx.label.name,
        linking_contexts = [cc_common.create_linking_context(
            linker_inputs = depset(indirect_linking_contexts),
        )],
        force_alwayslink_contexts = [cc_common.create_linking_context(
            linker_inputs = depset(direct_linking_contexts),
        )],
        stamp = ctx.attr.stamp,
    )
    runfiles = _merge_runfiles(
        ctx.runfiles(files = [nativedeps_lib]),
        [dep[PyNativeDepset].runfiles for dep in ctx.attr.deps],
    )
    return [DefaultInfo(runfiles = runfiles)]

py_library_deps = rule(
    implementation = _py_toplevel_target_impl,
    fragments = ["cpp"],
    attrs = {
        "deps": attr.label_list(aspects = [python_module_placeholder_aspect]),
        "stamp": attr.int(default = -1),
        "_cc_toolchain": attr.label(default = "@bazel_tools//tools/cpp:current_cc_toolchain"),
    },
)
