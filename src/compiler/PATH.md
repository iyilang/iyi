# Bootstrap path

The compiler written in iyi must compile iyi source through its own frontend,
native code generator and linker. The hosted compiler builds the first executable.
Its use ends only after that executable can build its successor.

## Acceptance order

| Input | Required observation |
|---|---|
| Prelude-free lowering fixtures | Typed-pipeline binaries match hosted stdout and exit status. |
| `samples/iyi/hello.iyi` with the iyi prelude | The complete runtime is emitted and the binary runs equal to hosted. |
| `src/compiler/tools/parse.iyi` | The generated parser runs and produces the hosted parser's output on the same source. |
| `src/compiler/tools/compile_native.iyi` | The typed pipeline reaches the native compiler tool's source and reports its reached phase. |
| `src/compiler/stage1.iyi` | Stage 1 builds stage 2; stage 2 builds stage 3 from the same source and options; stage 2 and stage 3 are byte-identical. |

The first host is aarch64-darwin. Later releases use the preceding iyi release as
their bootstrap compiler. Keep the hosted bootstrap available until the fixed
point and the compiler's own entry path pass.

## Running the current pipeline check

From the repository root, with its hosted `bin/iyi` built:

```sh
bash bench/selfhost_pipeline_exercise.sh
```

The gate builds the native compiler tool, checks its linked libraries for LLVM,
and exercises `--pipeline typed`. Prelude programs use `IYI_PATH="$PWD/src"`
and `--prelude`. Section 3 records the phase each root reaches. A root that links
is executed and compared with the hosted build; its final phase is `run-equal`.
A refusal must exit nonzero without leaving an executable.
`bash bench/selfhost_stage_one_exercise.sh` exercises the hosted-built stage-one
command entry, including native `build`, `run`, source protection, and named
refusals. It measures those entry paths independently of the pipeline census.


`bench/selfhost_pipeline.floor` records demonstrated phases. `PIPELINE.md`
records the current refusals. Reached, typed and lowered function counts explain
remaining work; they do not establish that a root compiles or runs.

## Final self-build proof

Build stage 1 from `src/compiler/stage1.iyi` with the hosted compiler. Run
stage 1 with `build` on that same source, writing stage 2. Run stage 2 with the
same source and options, writing stage 3. Use the same output basename in two
separate directories: the Mach-O signature includes that basename. Compare
the two binaries and exercise the resulting compiler on hello and the parser
input corpus. Check signatures and linked libraries, and record the exact
source revision and commands with the proof.

A fixed point produced from hosted-generated IR proves the native backend and
linker. The final proof also requires iyi's own frontend to read and type the
compiler source, with no hosted compiler or LLVM invoked during those builds.
