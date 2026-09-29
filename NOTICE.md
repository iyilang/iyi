# Crystal Programming Language

Copyright 2012-2026 Manas Technology Solutions.

This product includes software developed at Manas Technology Solutions (<https://manas.tech/>).

Apache License v2.0 with Swift exception applies to all works unless specified
otherwise:

Please see [REUSE.toml](REUSE.toml) and [LICENSE](LICENSE) for additional
copyright and licensing information.

- A shard installed into `/lib/` carries its own licence. See
  [REUSE.toml](REUSE.toml) for details. iyi vendors none: `markd` and
  `sanitize` went with the documentation generator, `reply` with the
  interpreter.

## External libraries information

Crystal compiler links the following libraries, which have their own license:

- [LLVM][] - [Apache-2.0 with LLVM exceptions][]
- [PCRE or PCRE2][] - [BSD-3][]
- [libevent2][] - [BSD-3][]
- [libiconv][] - [LGPLv3][]
- [bdwgc][] - [MIT][]

Crystal compiler calls the following tools as external process on compiling, which have their own license:

- [pkg-config](https://www.freedesktop.org/wiki/Software/pkg-config/) - [GPLv3]

Crystal standard library uses the following libraries, which have their own licenses:

- [LLVM][] - [Apache-2.0 with LLVM exceptions][]
- [PCRE or PCRE2][] - [BSD-3][]
- [libevent2][] - [BSD-3][]
- [libiconv][] - [LGPLv3][]
- [bdwgc][] - [MIT][]
- [Zlib][] - [Zlib][Zlib-license]
- [OpenSSL][] - [Apache-2.0][]
- [Libxml2][] - [MIT][]
- [LibYAML][] - [MIT][]
- [readline][] - [GPLv3][]
- [GMP][] - [LGPLv3][]

iyi's own standard library includes code derived from, and its benches a
port of:

- [Arm optimized-routines][] (`Math.exp` and `Math.pow` in `src/std/math.iyi`, and
  `bench/arm_math/`) - [MIT][]
- [crystal-metric][] (`bench/metric/`) - [MIT][]

<!-- licenses -->
[Apache-2.0]: https://www.openssl.org/source/apache-license-2.0.txt
[Apache-2.0 with LLVM exceptions]: https://raw.githubusercontent.com/llvm/llvm-project/main/llvm/LICENSE.TXT
[BSD-3]: https://opensource.org/licenses/BSD-3-Clause
[GPLv3]: https://www.gnu.org/licenses/gpl-3.0.en.html
[LGPLv3]: https://www.gnu.org/licenses/lgpl-3.0.en.html
[MIT]: https://opensource.org/licenses/MIT
[Zlib-license]: https://opensource.org/licenses/Zlib
<!-- libraries -->
[Arm optimized-routines]: https://github.com/ARM-software/optimized-routines
[crystal-metric]: https://github.com/kostya/crystal-metric
[bdwgc]: http://www.hboehm.info/gc/
[GMP]: https://gmplib.org/
[libevent2]: http://libevent.org/
[libiconv]: https://www.gnu.org/software/libiconv/
[Libxml2]: http://xmlsoft.org/
[LibYAML]: http://pyyaml.org/wiki/LibYAML
[LLVM]: http://llvm.org/
[OpenSSL]: https://www.openssl.org/
[PCRE or PCRE2]: http://pcre.org/
[readline]: https://tiswww.case.edu/php/chet/readline/rltop.html
[Zlib]: http://www.zlib.net/
