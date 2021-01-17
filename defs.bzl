""""Alternative rules for Python and for Python native libraries."""

load(":py_native.bzl",
    _NATIVE_DEPS_NAME = "NATIVE_DEPS_NAME",
    _PLACEHOLDER_NAME = "PLACEHOLDER_NAME",
    _py_library_deps = "py_library_deps",
    _py_native_module = "py_native_module")
load("@rules_cc//cc:defs.bzl", "cc_library")
load("@rules_python//python:defs.bzl",
    _py_binary = "py_binary",
    _py_library = "py_library",
    _py_test = "py_test")

def py_native_library(name, visibility = None, **kwargs):
    """A wrapper around cc_library.

    py_native_library targets may be passed as native_deps to the py_* wrappers.
    """
    cc_library(
        name = "_%s" % name,
        alwayslink = 1,
        **kwargs,
    )
    _py_native_module(
        name = name,
        cc_library = "_%s" % name,
        visibility = visibility,
    )

def py_library(name, deps = [], native_deps = [], visibility = None, **kwargs):
    """A wrapper around py_library, adding native_deps support."""
    _py_library(
        name = "_%s" % name,
        deps = deps,
        **kwargs,
    )
    _py_library_deps(
        name = name,
        py_library = "_%s" % name,
        native_deps = native_deps,
        deps = deps,
        visibility = visibility,
    )

def _py_toplevel_target(py_rule, name, data = [], deps = [], native_deps = [], **kwargs):
    # We can't pass in the same target as an attribute, and we don't have
    # access to the current label from the transition. We therefore pass in a
    # sibling target as the toplevel target and later deduce the name and path
    # of the toplevel target (see py_native.bzl).
    native.filegroup(name = "_%s%s" % (name, _PLACEHOLDER_NAME))
    _py_library_deps(
        name = "_%s%s" % (name, _NATIVE_DEPS_NAME),
        toplevel = "_%s%s" % (name, _PLACEHOLDER_NAME),
        native_deps = native_deps,
        deps = deps,
    )
    py_rule(
        name = name,
        data = data + ["_%s%s" % (name, _NATIVE_DEPS_NAME)],
        deps = deps,
        **kwargs,
    )

def py_binary(*args, **kwargs):
    """A wrapper around py_binary, adding native_deps support."""
    _py_toplevel_target(_py_binary, *args, **kwargs)

def py_test(*args, **kwargs):
    """A wrapper around py_test, adding native_deps support."""
    _py_toplevel_target(_py_test, *args, **kwargs)
