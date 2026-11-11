#!/usr/bin/env bash
# Exercises `std/bool`: eager | & ^, to_unsafe, and a hash that tells true from false.
# The program is a test (`bench/std_bool_test.iyi`), run by `iyi test`
# through `bench/module_test.sh`.
#
#     bash bench/std_bool_exercise.sh
MODULE=bool
. "$(cd "$(dirname "$0")" && pwd)/module_test.sh"

module_test_holds 2 "operators" "hash"
# A hash that answers one number for both, which only the hash case reads.
module_test_breaks 'self ? 1231 : 1237' '1231' "hash"
module_test_end
