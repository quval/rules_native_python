"""Rules for handling native dependencies for Python targets.

Provides two rules:
- py_library_deps: tracks the transitive dependencies of a py_* rule. When a
  toplevel target (py_binary or py_test) is given, all the native dependencies
  are linked together into a statically-linked shared object. Otherwise, it
  acts as a thin wrapper around the given py_library.
- py_native_module: provides the linking context of a cc_library so it can be
  linked into the native deps library, and provides an empty shared object that
  is dynamically linked into it instead.

The toplevel target is propagated from py_library_deps into py_native_modules
using a transition. Unfortunately, it is impossible to pass in the actual
native deps target through the transition, so we link against an empty
placeholder library.
"""

load(":cc_tools.bzl", "link_so", "link_with_placeholder")

EMPTY_TOPLEVEL = Label("@rules_native_python//:empty")
TOPLEVEL_FLAG = "@rules_native_python//:toplevel"
PLACEHOLDER_NAME = "_placeholder"
NATIVE_DEPS_NAME = "_native_deps"

PyNativeDepset = provider(fields = ["deps"])
PyNativeLibrary = provider(fields = ["linking_context"])

def _propagate_toplevel_impl(settings, attr):
    return {
        TOPLEVEL_FLAG: attr.toplevel or settings[TOPLEVEL_FLAG],
    }

_propagate_toplevel = transition(
    implementation = _propagate_toplevel_impl,
    inputs = [TOPLEVEL_FLAG],
    outputs = [TOPLEVEL_FLAG],
)

def _stop_propagation_impl(settings, attr):
    return {
        TOPLEVEL_FLAG: EMPTY_TOPLEVEL,
    }

_stop_propagation = transition(
    implementation = _stop_propagation_impl,
    inputs = [],
    outputs = [TOPLEVEL_FLAG],
)

def _py_library_deps_impl(ctx):
    if bool(ctx.attr.toplevel) == bool(ctx.attr.py_library):
        fail("Exactly one of toplevel and py_library must be set")

    all_deps = depset(direct = ctx.attr.native_deps, transitive = [
        dep[PyNativeDepset].deps for dep in ctx.attr.deps if PyNativeDepset in dep
    ])

    if not ctx.attr.toplevel:
        return [
            DefaultInfo(runfiles = ctx.attr.py_library.default_runfiles),
            PyNativeDepset(deps = all_deps),
            ctx.attr.py_library[PyInfo],
        ]

    runfiles = ctx.runfiles()
    linking_contexts = []
    for dep in all_deps.to_list():
        runfiles = runfiles.merge(dep.default_runfiles)
        linking_contexts.append(dep[PyNativeLibrary].linking_context)
    runfiles = runfiles.merge(ctx.runfiles([link_so(
        ctx = ctx,
        name = ctx.label.name,
        linking_contexts = linking_contexts,
        stamp = ctx.attr.stamp,
    )]))
    return [
        DefaultInfo(runfiles = runfiles),
        PyNativeDepset(deps = all_deps),
    ]

py_library_deps = rule(
    implementation = _py_library_deps_impl,
    cfg = _propagate_toplevel,
    fragments = ["cpp"],
    attrs = {
        "deps": attr.label_list(),
        "native_deps": attr.label_list(),
        "py_library": attr.label(),
        "stamp": attr.int(default = -1),
        "toplevel": attr.label(),
        "_cc_toolchain": attr.label(default = "@bazel_tools//tools/cpp:current_cc_toolchain"),
        "_whitelist_function_transition": attr.label(
            default = "@bazel_tools//tools/whitelists/function_transition_whitelist",
        ),
    },
)

def _py_native_module_impl(ctx):
    target_label = ctx.attr._toplevel.label
    if target_label == EMPTY_TOPLEVEL:
        return

    # We cannot link with the actual native deps library, so we link with an
    # empty placeholder. The right library is provided by the py_library_deps
    # target (which will have propagated _toplevel, or we wouldn't get here).
    module = ctx.actions.declare_file(ctx.label.name + ".so")
    link_with_placeholder(
        ctx = ctx,
        output = module,
        target_path = target_label.package,
        target_name = target_label.name.replace(PLACEHOLDER_NAME, NATIVE_DEPS_NAME),
    )
    runfiles = ctx.runfiles([module]).merge(ctx.attr.cc_library[0].default_runfiles)
    return [
        DefaultInfo(runfiles = runfiles),
        PyNativeLibrary(linking_context = ctx.attr.cc_library[0][CcInfo].linking_context),
    ]

py_native_module = rule(
    implementation = _py_native_module_impl,
    fragments = ["cpp"],
    attrs = {
        "cc_library": attr.label(cfg = _stop_propagation),
        "_toplevel": attr.label(default = TOPLEVEL_FLAG),
        "_cc_toolchain": attr.label(default = "@bazel_tools//tools/cpp:current_cc_toolchain"),
        "_whitelist_function_transition": attr.label(
            default = "@bazel_tools//tools/whitelists/function_transition_whitelist",
        ),
    },
)
