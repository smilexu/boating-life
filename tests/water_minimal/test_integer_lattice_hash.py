"""CPU reference regression for the sea-water integer lattice hash."""

from math import floor, isclose
from pathlib import Path
import re


MASK = 0xFFFFFFFF
UINT_X = 0x8DA6B343
UINT_Y = 0xD8163841
UINT_BIAS = 0xCB1AB31F
MIX_A = 0x7FEB352D
MIX_B = 0x846CA68B


def lattice_hash(x: int, y: int) -> tuple[int, float]:
    value = ((x & MASK) * UINT_X) & MASK
    value ^= ((y & MASK) * UINT_Y) & MASK
    value ^= UINT_BIAS
    value ^= value >> 16
    value = (value * MIX_A) & MASK
    value ^= value >> 15
    value = (value * MIX_B) & MASK
    value ^= value >> 16
    return value, (value >> 8) / 16777216.0


def value_noise_gradient(x: float, y: float) -> tuple[float, float, float]:
    cell_x, cell_y = floor(x), floor(y)
    fx, fy = x - cell_x, y - cell_y

    def fade(t: float) -> float:
        return t * t * t * (t * (t * 6.0 - 15.0) + 10.0)

    def fade_derivative(t: float) -> float:
        return 30.0 * t * t * (t - 1.0) * (t - 1.0)

    ux, uy = fade(fx), fade(fy)
    dux, duy = fade_derivative(fx), fade_derivative(fy)
    n00 = lattice_hash(cell_x, cell_y)[1]
    n10 = lattice_hash(cell_x + 1, cell_y)[1]
    n01 = lattice_hash(cell_x, cell_y + 1)[1]
    n11 = lattice_hash(cell_x + 1, cell_y + 1)[1]
    row0 = n00 + (n10 - n00) * ux
    row1 = n01 + (n11 - n01) * ux
    value = row0 + (row1 - row0) * uy
    gradient_x = ((n10 - n00) * (1.0 - uy) + (n11 - n01) * uy) * dux
    gradient_y = (row1 - row0) * duy
    return value, gradient_x, gradient_y


def test_integer_hash_reference() -> None:
    assert lattice_hash(5271, 9770) == (4078356539, 0.9495663642883301)
    assert lattice_hash(5272, 9770) == (903148787, 0.2102806568145752)
    for point in ((5271, 9770), (5272, 9770), (-17, 23), (0, 0)):
        integer_value, float_value = lattice_hash(*point)
        assert 0 <= integer_value <= MASK
        assert 0.0 <= float_value < 1.0


def test_shared_corners_are_identical() -> None:
    left_cell = (5271, 9770)
    right_cell = (5272, 9770)
    shared_from_left = (left_cell[0] + 1, left_cell[1])
    shared_from_right = (right_cell[0], right_cell[1])
    assert shared_from_left == shared_from_right
    assert lattice_hash(*shared_from_left) == lattice_hash(*shared_from_right)

    lower_cell = (5271, 9770)
    upper_cell = (5271, 9771)
    shared_from_lower = (lower_cell[0], lower_cell[1] + 1)
    shared_from_upper = (upper_cell[0], upper_cell[1])
    assert shared_from_lower == shared_from_upper
    assert lattice_hash(*shared_from_lower) == lattice_hash(*shared_from_upper)


def test_value_noise_gradient_is_continuous_at_shared_edges() -> None:
    epsilon = 1e-5
    for point in ((5271.0, 9770.375), (5271.375, 9770.0)):
        x, y = point
        if x.is_integer():
            left = value_noise_gradient(x - epsilon, y)
            right = value_noise_gradient(x + epsilon, y)
        else:
            left = value_noise_gradient(x, y - epsilon)
            right = value_noise_gradient(x, y + epsilon)
        for left_value, right_value in zip(left, right):
            assert isclose(left_value, right_value, rel_tol=0.0, abs_tol=2e-6), (
                point,
                left,
                right,
            )


def test_shader_uses_integer_hash_for_all_value_noise_corners() -> None:
    shader_path = Path(__file__).resolve().parents[2] / "shaders" / "sea_water.gdshader"
    shader = shader_path.read_text(encoding="utf-8")
    hash_match = re.search(
        r"float water_integer_lattice_hash\(ivec2 lattice\) \{(.*?)\n\}",
        shader,
        re.DOTALL,
    )
    noise_match = re.search(
        r"vec3 water_value_noise_gradient\(vec2 p\) \{(.*?)\n\}",
        shader,
        re.DOTALL,
    )
    assert hash_match is not None
    assert noise_match is not None
    hash_body = hash_match.group(1)
    noise_body = noise_match.group(1)

    for token in (
        "uint(lattice.x)",
        "uint(lattice.y)",
        "0x8da6b343u",
        "0xd8163841u",
        "hash_value >> 8u",
    ):
        assert token in hash_body
    assert "ivec2 integer_cell = ivec2(cell);" in noise_body
    assert noise_body.count("water_integer_lattice_hash(") == 4
    assert "water_hash(" not in noise_body


if __name__ == "__main__":
    test_integer_hash_reference()
    test_shared_corners_are_identical()
    test_value_noise_gradient_is_continuous_at_shared_edges()
    test_shader_uses_integer_hash_for_all_value_noise_corners()
    print("Integer lattice hash regression passed.")
