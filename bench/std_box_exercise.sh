#!/usr/bin/env bash
# Exercises `std/box`: heap box holding a value.
# The program is a test (`bench/std_box_test.iyi`), run by `iyi test`
# through `bench/module_test.sh`.
#
#     bash bench/std_box_exercise.sh
MODULE=box
. "$(cd "$(dirname "$0")" && pwd)/module_test.sh"

module_test_holds 2 "new, object, box and unbox" "a null pointer is nil for a nilable T"
# A box that hands C a null pointer instead of the object. Breaking `unbox`
# with a `raise` instead made the program fail to build, which an exit
# status alone read as the test catching it; a case that fails is the proof.
module_test_breaks 'new(object).as(Void*)' 'Pointer(Void).new(0_u64)' "new, object, box and unbox"
module_test_end
