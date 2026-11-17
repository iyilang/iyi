#!/usr/bin/env bash
# Exercises `std/heap`.
# The program is a test (`bench/std_heap_test.iyi`), run by `iyi test`
# through `bench/module_test.sh`.
#
#     bash bench/std_heap_exercise.sh
MODULE=heap
. "$(cd "$(dirname "$0")" && pwd)/module_test.sh"

module_test_holds 1 "min-heap pop order"
# A sift that keeps the larger item on top: a max-heap where a min-heap was.
module_test_breaks 'break unless (@items[i] <=> @items[p]) < 0' 'break unless (@items[i] <=> @items[p]) > 0' "min-heap pop order"
module_test_end
