""""Alternative rules for Python and for Python native libraries."""

load(":py_native.bzl",
    _configure_nativedeps = "configure_nativedeps",
    _py_library_deps = "py_library_deps",
    _py_native_module = "py_native_module")
load("@rules_cc//cc:defs.bzl", "cc_library")
load("@rules_python//python:defs.bzl",
    _py_binary = "py_binary",
    _py_library = "py_library",
    _py_test = "py_test")

def py_native_module(name, visibility = None, **kwargs):
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

def _py_toplevel_target(py_rule, name, data = [], deps = [], stamp = None, **kwargs):
    _py_library_deps(
        name = "_%s_nativedeps" % name,
        stamp = stamp,
        deps = deps,
    )
    _configure_nativedeps(
        name = "_%s_configured_nativedeps" % name,
        actual = "_%s_nativedeps" % name,
    )
    py_rule(
        name = name,
        data = data + [
            "_%s_nativedeps" % name,
            "_%s_configured_nativedeps" % name,
        ],
        deps = deps,
        stamp = stamp,
        **kwargs,
    )

def py_binary(*args, **kwargs):
    """A wrapper around py_binary, adding native_deps support."""
    _py_toplevel_target(_py_binary, *args, **kwargs)

def py_test(*args, **kwargs):
    """A wrapper around py_test, adding native_deps support."""
    _py_toplevel_target(_py_test, *args, **kwargs)

py_library = _py_library
