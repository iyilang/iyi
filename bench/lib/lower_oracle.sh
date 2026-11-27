# Shared by the lowering gates (bench/selfhost_lower_*_exercise.sh): the oracle module
# text the port's IR parser reads. Sourced, not run.
#
# CALL_TYPES is an awk program. It writes the forms LLVM 22 leaves out and the port's
# text form requires: call signatures, phi labels, atomic memory operation ordering,
# and a landingpad's personality and clauses on its own line. Indirect calls with
# multiword argument types remain unchanged.
CALL_TYPES='
function call_types(line,   p, rest, ret, after, op, cl, args, tail, n, parts, w, types, i, head, name, at, indirect, len) {
  p = index(line, " call ")
  len = 6
  if (p == 0) { p = index(line, " invoke "); len = 8 }
  if (p == 0) return line
  head = substr(line, 1, p + len - 1)
  rest = substr(line, p + len)
  at = index(rest, " @")
  indirect = 0
  if (match(rest, / %([a-zA-Z0-9$._-]+|"[^"]+")\(/) && (at == 0 || RSTART < at)) {
    at = RSTART
    indirect = 1
  }
  if (at == 0) return line
  ret = substr(rest, 1, at - 1)
  after = substr(rest, at + 1)
  if (substr(after, 1, 1) != "@" && substr(after, 1, 1) != "%") return line
  op = name_end(after) + 1
  if (op == 1 || substr(after, op, 1) != "(") return line
  cl = close_paren(after, op)
  if (cl == 0) return line
  name = substr(after, 1, op - 1)
  args = substr(after, op + 1, cl - op - 1)
  tail = substr(after, cl + 1)
  if (substr(tail, 1, 2) == " #") {
    if (len == 8) sub(/^ #[0-9]+/, "", tail)
    else tail = ""
  }
  n = split_top(args, parts)
  types = ""
  for (i = 1; i <= n; i++) {
    split(parts[i], w, " ")
    if (indirect && ((w[1] != "" && index("[<{", substr(w[1], 1, 1)) > 0) || w[2] ~ /^addrspace\(/ || (w[1] ~ /^%"/ && w[1] !~ /"$/))) return line
    types = types (i > 1 ? ", " : "") arg_type(parts[i])
  }
  if (indirect || name ~ /^@"[*~]/ || name ~ /^@(__crystal_main|__iyi_main)$/) ret = "iyicc " ret
  return head ret " (" types ") " name "(" args ")" tail
}
function arg_type(s,   i, c, depth, open_c, close_c, w) {
  if (substr(s, 1, 2) == "%\"") {
    for (i = 3; i <= length(s); i++) if (substr(s, i, 1) == "\"") return substr(s, 1, i)
  }
  open_c = substr(s, 1, 1)
  if (open_c == "{" || open_c == "[") {
    close_c = (open_c == "{") ? "}" : "]"
    depth = 0
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1)
      if (c == open_c) depth++
      else if (c == close_c) { depth--; if (depth == 0) return substr(s, 1, i) }
    }
  }
  split(s, w, " ")
  return w[1]
}
# The last character of the callee name that starts `s` (`@name` or `@"quoted name"`), or 0. A quoted
# name holds parentheses of its own (`@"*Box(Int32)^Box(T)::new<Int32>:Box(Int32)"`), which are not the call.
function name_end(s,   i) {
  if (substr(s, 2, 1) != "\"") return index(s, "(") - 1
  for (i = 3; i <= length(s); i++) if (substr(s, i, 1) == "\"") return i
  return 0
}
# The parenthesis that closes the one at `op`, outside quoted names, or 0.
function close_paren(s, op,   i, c, depth, quoted) {
  depth = 0; quoted = 0
  for (i = op; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c == "\"") quoted = !quoted
    else if (!quoted && c == "(") depth++
    else if (!quoted && c == ")") { depth--; if (depth == 0) return i }
  }
  return 0
}
# Splits the argument list of a call at its top-level commas, so a constant expression with commas
# (`getelementptr (T, ptr null, i32 1)`) stays whole, and a quoted name (`%"Pair(Int32, Bool)"`) too.
function split_top(s, out,   i, c, depth, cur, n, quoted) {
  n = 0; depth = 0; cur = ""; quoted = 0
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c == "\"") quoted = !quoted
    else if (!quoted && c == "(") depth++
    else if (!quoted && c == ")") depth--
    if (c == "," && depth == 0 && !quoted) { out[++n] = cur; cur = ""; if (substr(s, i + 1, 1) == " ") i++; continue }
    cur = cur c
  }
  out[++n] = cur
  return n
}
# An argument of an intrinsic call in the IR text form: its type, then its value. `align N`
# is written `align(N)` in front of the type, as the IR fixtures write it. The other parameter
# attributes LLVM prints (writeonly, nocapture, captures, noundef, immarg, ...) are dropped.
function fix_arg(a,   n, w, i, aligns, typ, rest, tok) {
  n = split(a, w, " ")
  typ = w[1]; rest = ""; aligns = ""
  for (i = 2; i <= n; i++) {
    tok = w[i]
    if (tok == "align") { aligns = "align(" w[i + 1] ") "; i++; continue }
    if (tok ~ /^(writeonly|readonly|nocapture|noundef|immarg|nonnull|noalias|nofree|readnone|captures\()/) continue
    rest = rest (rest == "" ? "" : " ") tok
  }
  return aligns typ (rest == "" ? "" : " " rest)
}
# An intrinsic call `[%r = ]call T @llvm.NAME(ARGS)` as the IR text form writes it:
# `[%r = ]intrinsic llvm.NAME(ARGS)`.
function intrinsic_line(line,   p, lhs, rest, ret, after, op, k, cl, name, args, n, parts, m, parts2, out, i, at) {
  p = index(line, " call ")
  lhs = substr(line, 1, p - 1)
  rest = substr(line, p + 6)
  at = index(rest, " @")
  ret = substr(rest, 1, at - 1)
  after = substr(rest, at + 1)
  op = index(after, "(")
  cl = 0
  for (k = length(after); k > 0; k--) if (substr(after, k, 1) == ")") { cl = k; break }
  name = substr(after, 2, op - 2)
  args = substr(after, op + 1, cl - op - 1)
  m = split_top(args, parts2)
  out = ""
  for (i = 1; i <= m; i++) out = out (i > 1 ? ", " : "") fix_arg(parts2[i])
  if (lhs ~ /=$/) return lhs " intrinsic " name "(" out ")"
  return lhs "intrinsic " name "(" out ")"
}
# Hosted writes ccc; compiler-generated functions and both program entries use Iyi.
function cc_define(line,   at, head, p, rest, sp, kw) {
  at = index(line, " @")
  head = substr(line, 1, at - 1)
  p = index(head, " ")
  if (p == 0) return line
  rest = substr(head, p + 1)
  sp = index(rest, " ")
  if (sp > 0) {
    kw = substr(rest, 1, sp - 1)
    if (kw ~ /^(internal|external|private|linkonce_odr|weak_odr|common|appending|available_externally|dso_local|unnamed_addr)$/) {
      return substr(head, 1, p) kw " iyicc " substr(rest, sp + 1) substr(line, at)
    }
  }
  return substr(head, 1, p) "iyicc " rest substr(line, at)
}
# LLVM writes `load atomic T, ptr %p acquire, align N`; the IR text puts
# `atomic acquire` after the alignment. Volatile precedes the operation.
function atomic_memory(line,   p, suffix, prefix, words) {
  if (index(line, "atomicrmw ") && match(line, / (monotonic|acquire|release|acq_rel|seq_cst), align [0-9]+$/)) {
    suffix = substr(line, RSTART + 1)
    prefix = substr(line, 1, RSTART - 1)
    split(suffix, words, /[ ,]+/)
    return prefix ", align " words[3] " " words[1]
  }
  if (index(line, "cmpxchg ") && match(line, / (monotonic|acquire|release|acq_rel|seq_cst) (monotonic|acquire|seq_cst), align [0-9]+$/)) {
    suffix = substr(line, RSTART + 1)
    prefix = substr(line, 1, RSTART - 1)
    split(suffix, words, /[ ,]+/)
    return prefix ", align " words[4] " " words[1] " " words[2]
  }
  if (!(index(line, "load atomic ") || index(line, "store atomic "))) return line
  if (!match(line, / (unordered|monotonic|acquire|release|acq_rel|seq_cst), align [0-9]+$/)) return line
  suffix = substr(line, RSTART + 1)
  prefix = substr(line, 1, RSTART - 1)
  split(suffix, words, /[ ,]+/)
  if (index(prefix, "load atomic volatile ")) sub(/load atomic volatile /, "volatile load ", prefix)
  else if (index(prefix, "store atomic volatile ")) sub(/store atomic volatile /, "volatile store ", prefix)
  else {
    sub(/load atomic /, "load ", prefix)
    sub(/store atomic /, "store ", prefix)
  }
  return prefix ", align " words[3] " atomic " words[1]
}
# A call operand that LLVM 20 folds into a `mul` constant expression,
# `%K = call ptr @f(i64 mul (i64 A, i64 B))`, is written the way LLVM 21 and later write it, and
# the way the port does: `%K = mul i64 A, B` and the call on `i64 %K`. Every later numbered value of
# the function moves up one, so the whole function is read before any of it is written
# (a phi may name a value defined below it).
function folded_mul(line,   p, q, depth, c, inner, n, parts) {
  if (line !~ /^  %[0-9]+ = call /) return ""
  p = index(line, "(i64 mul (i64 ")
  if (p == 0) return ""
  q = p + 9
  depth = 0
  for (; q <= length(line); q++) {
    c = substr(line, q, 1)
    if (c == "(") depth++
    else if (c == ")") { depth--; if (depth == 0) break }
  }
  if (depth != 0 || substr(line, q + 1, 1) != ")") return ""
  inner = substr(line, p + 10, q - p - 10)
  n = split_top(inner, parts)
  if (n != 2 || parts[1] !~ /^i64 / || parts[2] !~ /^i64 /) return ""
  fold_head = substr(line, 1, p)
  fold_tail = substr(line, q + 1)
  return substr(parts[1], 5) ", " substr(parts[2], 5)
}
function renumber(line, thresholds, count,   out, m, j, shift) {
  if (count == 0) return line
  out = ""
  while (match(line, /%[0-9]+/)) {
    m = substr(line, RSTART + 1, RLENGTH - 1) + 0
    shift = 0
    for (j = 1; j <= count; j++) if (thresholds[j] <= m) shift++
    out = out substr(line, 1, RSTART) (m + shift)
    line = substr(line, RSTART + RLENGTH)
  }
  return out line
}
function flush_function(   i, count, thresholds, operands, k, lt, j, temp) {
  count = 0
  for (i = 1; i <= nbuf; i++) {
    if (folded_mul(buf[i]) != "") {
      match(buf[i], /%[0-9]+/)
      thresholds[++count] = substr(buf[i], RSTART + 1, RLENGTH - 1) + 0
    }
  }
  for (i = 1; i <= nbuf; i++) {
    operands = folded_mul(buf[i])
    if (operands == "") { emit(renumber(buf[i], thresholds, count)); continue }
    match(buf[i], /%[0-9]+/)
    k = substr(buf[i], RSTART + 1, RLENGTH - 1) + 0
    lt = 0
    for (j = 1; j <= count; j++) if (thresholds[j] < k) lt++
    temp = k + lt
    emit("  %" temp " = mul i64 " operands)
    sub(/^  %[0-9]+ = /, "  %" (temp + 1) " = ", fold_head)
    emit(fold_head "i64 %" temp fold_tail)
  }
  nbuf = 0
}
# LLVM writes the personality on the function (`define ... personality ptr @p {`) and each
# landingpad clause on a line of its own; the IR text writes one line,
# `landingpad T personality ptr @p cleanup catch ptr @c`.
function emit(line,   clause) {
  if (pad != "") {
    if (line ~ /^[ \t]+(cleanup|catch |filter )/) { clause = line; sub(/^[ \t]+/, "", clause); pad = pad " " clause; return }
    print pad
    pad = ""
  }
  line = atomic_memory(line)
  if (line ~ /^define /) {
    personality = ""
    if (index(line, " personality ") > 0) { personality = line; sub(/^.* personality /, "", personality); sub(/ *\{$/, "", personality) }
  }
  if (personality != "" && line ~ /= landingpad / && index(line, " personality ") == 0) { pad = line " personality " personality; return }
  if (line ~ /^define .* @"[*~]/ || line ~ /^define .* @(__crystal_main|__iyi_main)\(/) line = cc_define(line)
  if (line ~ /^declare .*@llvm\./) return
  if (index(line, " phi ") > 0) gsub(/, %/, ", label %", line)
  if (index(line, "@llvm.") > 0 && index(line, " call ") > 0) { print intrinsic_line(line); return }
  if (index(line, " call ") > 0 || index(line, " invoke ") > 0) print call_types(line); else print line
}
{
  if ($0 ~ /^define .*\{$/) buffering = 1
  if (!buffering) { emit($0); next }
  buf[++nbuf] = $0
  if ($0 == "}") { flush_function(); buffering = 0 }
}
END {
  for (i = 1; i <= nbuf; i++) emit(buf[i])
  if (pad != "") print pad
}
'
