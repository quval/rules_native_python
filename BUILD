load(":native_py.bzl", "ACTUAL_NATIVEDEPS_DEFAULT", "nativedeps", "toplevel_binary")

toplevel_binary(
    name = "actual_nativedeps",
    build_setting_default = ACTUAL_NATIVEDEPS_DEFAULT,
    tags = ["manual"],
    visibility = ["//visibility:public"],
)

nativedeps(
    name = "nativedeps",
    tags = ["manual"],
    visibility = ["//visibility:public"],
)

nativedeps(
    name = "test_nativedeps",
    testonly = True,
    tags = ["manual"],
    visibility = ["//visibility:public"],
)
