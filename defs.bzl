""""Alternative rules for Python and for Python native libraries."""

load("@rules_cc//cc:defs.bzl", "cc_library")
load("@rules_python//python:defs.bzl", _py_binary = "py_binary", _py_library = "py_library", _py_test = "py_test")
load(":py_native.bzl", "configure_nativedeps", "configure_test_nativedeps", "py_library_deps", _py_native_module = "py_native_module")

def py_native_module(name, deps = None, testonly = None, visibility = None, **kwargs):
    """A wrapper around cc_library.

    py_native_library targets may be passed as deps to the py_* wrappers.
    """
    cc_library(
        name = "_%s" % name,
        deps = deps,
        testonly = testonly,
        **kwargs
    )
    _py_native_module(
        name = name,
        direct_deps = deps,
        cc_library = ":_%s" % name,
        testonly = testonly,
        visibility = visibility,
    )

def _py_toplevel_target(py_rule, name, data = [], deps = [], testonly = None, stamp = None, **kwargs):
    py_library_deps(
        name = "_%s_nativedeps" % name,
        stamp = stamp,
        deps = deps,
        testonly = testonly,
    )
    (configure_test_nativedeps if testonly else configure_nativedeps)(
        name = "_%s_configured_nativedeps" % name,
        actual = ":_%s_nativedeps" % name,
        testonly = testonly,
    )
    py_rule(
        name = name,
        data = data + [
            ":_%s_nativedeps" % name,
            ":_%s_configured_nativedeps" % name,
        ],
        deps = deps,
        stamp = stamp,
        **kwargs
    )

def py_binary(*args, **kwargs):
    """A wrapper around py_binary, adding native_deps support."""
    _py_toplevel_target(_py_binary, *args, **kwargs)

def py_test(*args, **kwargs):
    """A wrapper around py_test, adding native_deps support."""
    _py_toplevel_target(_py_test, testonly = True, *args, **kwargs)

py_library = _py_library
