""""Alternative rules for Python and for Python native libraries."""

load("@rules_python//python:defs.bzl", _py_binary = "py_binary", _py_library = "py_library", _py_test = "py_test")
load(":native_py.bzl", "configure_nativedeps", "configure_test_nativedeps", "py_library_deps", _py_native_module = "py_native_module")

py_native_module = _py_native_module

def _py_toplevel_target(py_rule, name, data = [], deps = [], direct_data = [], linkstatic = None, testonly = None, stamp = None, **kwargs):
    """A wrapper around a toplevel Python target.

    Args:
        py_rule: The toplevel rule (py_binary or py_test).
        name: The name of the target.
        data: Data dependencies.
        deps: Python dependencies.
        direct_data: Data dependencies that may be used in the args and env
          attributes. Shouldn't include py_binary or py_test targets, as we may
          need to prune their nativedeps libraries.
        linkstatic: Whether to link native dependencies statically. This is the
          default for py_binary and not for py_test, similarly to cc targets.
        testonly: If unset, defaults to True iff the toplevel rule is py_test.
        stamp: Whether to stamp the binary. Should usually be left unset.
        **kwargs: Forwarded as is to the Python rule.
    """
    if data or deps:
        py_library_deps(
            name = "_%s_deps" % name,
            stamp = stamp,
            data = data,
            deps = deps,
            tags = ["manual"],
            linkstatic = linkstatic if linkstatic != None else (py_rule != _py_test),
            testonly = testonly if testonly != None else (py_rule == _py_test),
        )
        (configure_test_nativedeps if testonly else configure_nativedeps)(
            name = "_%s_nativedeps" % name,
            deps = [":_%s_deps" % name],
            tags = ["manual"],
            testonly = testonly if testonly != None else (py_rule == _py_test),
        )
        py_rule(
            name = name,
            data = direct_data,
            deps = [":_%s_nativedeps" % name],
            stamp = stamp,
            testonly = testonly,
            **kwargs
        )
    else:
        py_rule(
            name = name,
            stamp = stamp,
            data = direct_data,
            testonly = testonly,
            **kwargs
        )

def py_binary(*args, **kwargs):
    """A wrapper around py_binary, adding native deps support."""
    _py_toplevel_target(_py_binary, *args, **kwargs)

def py_test(*args, **kwargs):
    """A wrapper around py_test, adding native deps support."""
    _py_toplevel_target(_py_test, *args, **kwargs)

py_library = _py_library
