#!/usr/bin/env bash
# Exercises `std/string_pool`: interned strings: the same bytes become one object.
# The program is a test (`bench/std_string_pool_test.iyi`), run by `iyi test`
# through `bench/module_test.sh`.
#
#     bash bench/std_string_pool_exercise.sh
MODULE=string_pool
. "$(cd "$(dirname "$0")" && pwd)/module_test.sh"

module_test_holds 1 "intern"
# A pool that never counts what it interned.
module_test_breaks '@size += 1' '# @size += 1' "intern"
module_test_end
