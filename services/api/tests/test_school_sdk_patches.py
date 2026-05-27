from app.school_sdk_patches import (
    DEFAULT_SCHEDULE_TIME,
    apply_school_sdk_import_patches,
    apply_school_sdk_patches,
    schedule_time_copy,
)


def test_schedule_time_extends_to_16_sections():
    schedule_time = schedule_time_copy()

    assert schedule_time["16"] == {"start": "2110", "end": "2150"}
    assert len(schedule_time) == 16


def test_schedule_time_copy_does_not_mutate_default():
    schedule_time = schedule_time_copy()

    schedule_time["16"]["start"] = "0000"

    assert DEFAULT_SCHEDULE_TIME["16"]["start"] == "2110"


def test_school_sdk_patch_is_safe_to_call_repeatedly():
    first = apply_school_sdk_patches()
    second = apply_school_sdk_patches()

    assert first == second


def test_school_sdk_import_patch_restores_ast_bytes():
    import ast

    original = getattr(ast, "Bytes", None)
    try:
        if hasattr(ast, "Bytes"):
            delattr(ast, "Bytes")

        apply_school_sdk_import_patches()

        assert ast.Bytes is ast.Constant
    finally:
        if original is not None:
            ast.Bytes = original
