load(":py_native.bzl", "nativedeps")

label_setting(
    name = "actual_nativedeps",
    build_setting_default = "//:all",  # Just a placeholder.
    visibility = ["//visibility:public"],
)

nativedeps(
    name = "nativedeps",
    visibility = ["//visibility:public"],
)
