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

- [Arm optimized-routines][] (`Math.exp`, `exp2`, `log`, `log2` and `pow` in `src/std/math.iyi`, and
  `bench/libm_oracle/`) - [MIT][]
- fdlibm, as glibc carries it (`Math.log10`, `expm1`, `log1p`, `sinh`, `cosh`,
  `tanh` and the Bessel functions, and their
  copies in `bench/libm_oracle/`) -
  Sun Microsystems' notice: "Permission to use, copy, modify, and
  distribute this software is freely granted, provided that this notice is
  preserved."
- [musl][] (`Math.fma`'s software arm in `src/std/math.iyi`) - [MIT][]
- [CORE-MATH][], as glibc 2.43 carries it and as published (`Math.erf`,
  `erfc`, `asinh`, `acosh`, `atanh`, `lgamma`, `tgamma`, `atan`, `asin`,
  `acos`, `sin`, `cos`, `tan`, `cbrt` and `hypot` in
  `src/std/math.iyi`, and `bench/libm_oracle/core_math/`) - [MIT][]
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
[musl]: https://musl.libc.org/
[CORE-MATH]: https://core-math.gitlabpages.inria.fr/
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
