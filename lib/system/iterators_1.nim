when sizeof(int) <= 2:
  type IntLikeForCount = int|int8|int16|char|bool|uint8|enum
else:
  type IntLikeForCount = int|int8|int16|int32|char|bool|uint8|uint16|enum

template getCountableValue(val, fallback: untyped): untyped =
  when val is IntLikeForCount and val is Ordinal:
    int(val)
  else:
    fallback(val)

iterator countupordown*[T, U](a: T, b: U, step: Positive = 1): T {.inline.} =
  ## Counts from ordinal value `a` up or down to `b` (inclusive) with the given
  ## step size.
  ##
  ## `T` may be any ordinal type, `step` may only be positive.
  ##
  ## **Note**: This fails to count to `low(int)` or `high(int)` if T = int for
  ## efficiency reasons.
  runnableExamples:
    import std/sugar
    let x = collect(newseq):
      for i in countupordown(2, 9, 3):
        i
    assert x == @[2, 5, 8]
    let y = collect(newseq):
      for i in countupordown(9, 2, 3):
        i
    assert y == @[9, 6, 3]
  mixin inc
  mixin `<`

  var
    avalue = getCountableValue(a, T)
    bvalue = getCountableValue(b, T)
    yieldedValue = addr avalue
    stepvalue: int = int(step)

  if avalue > bvalue:
    swap(avalue, bvalue)
    yieldedValue = addr bvalue
    stepvalue = -stepvalue

  while avalue <= bvalue:
    yield T(yieldedValue[])
    when avalue is (uint|uint64):
      if avalue == bvalue: break
    inc(yieldedValue[], stepvalue)

iterator countdown*[T, U](a: T, b: U, step: Positive = 1): T {.inline.} =
  ## Counts from ordinal value `a` down to `b` (inclusive) with the given
  ## step size.
  ##
  ## `T` may be any ordinal type, `step` may only be positive.
  ##
  ## **Note**: This fails to count to `low(int)` if T = int for
  ## efficiency reasons.
  runnableExamples:
    import std/sugar
    let x = collect(newSeq):
      for i in countdown(7, 3):
        i
    
    assert x == @[7, 6, 5, 4, 3]

    let y = collect(newseq):
      for i in countdown(9, 2, 3):
        i
    assert y == @[9, 6, 3]

  if getCountableValue(a, T) >= getCountableValue(b, T):
    for i in countupordown(a, b, step):
      yield i

iterator countup*[T, U](a: T, b: U, step: Positive = 1): T {.inline.} =
  ## Counts from ordinal value `a` to `b` (inclusive) with the given
  ## step size.
  ##
  ## `T` may be any ordinal type, `step` may only be positive.
  ##
  ## **Note**: This fails to count to `high(int)` if T = int for
  ## efficiency reasons.
  runnableExamples:
    import std/sugar
    let x = collect(newSeq):
      for i in countup(3, 7):
        i
    
    assert x == @[3, 4, 5, 6, 7]

    let y = collect(newseq):
      for i in countup(2, 9, 3):
        i
    assert y == @[2, 5, 8]
  if getCountableValue(a, T) <= getCountableValue(b, T):
    for i in countupordown(a, b, step):
      yield i

iterator `..`*[T, U](a: T, b: U): T {.inline.} =
  ## An alias for `countup(a, b)`.
  ##
  ## See also:
  ## * [..<](#..<.i,T,U)
  runnableExamples:
    import std/sugar

    let x = collect(newSeq):
      for i in 3 .. 7:
        i

    assert x == @[3, 4, 5, 6, 7]
  for i in countup(a, b):
    yield i

iterator `..<`*[T, U](a: T, b: U): T {.inline.} =
  ## An alias for `countup(a, pred(b))`.
  ##
  ## See also:
  ## * [..](#...i,T,U)
  for i in countup(a, pred(b)):
    yield i

iterator `||`*[S, T](a: S, b: T, annotation: static string = "parallel for"): T {.
  inline, magic: "OmpParFor", sideEffect.} =
  ## OpenMP parallel loop iterator. Same as `..` but the loop may run in parallel.
  ##
  ## `annotation` is an additional annotation for the code generator to use.
  ## The default annotation is `parallel for`.
  ## Please refer to the `OpenMP Syntax Reference
  ## <https://www.openmp.org/wp-content/uploads/OpenMP-4.5-1115-CPP-web.pdf>`_
  ## for further information.
  ##
  ## Note that the compiler maps that to
  ## the `#pragma omp parallel for` construct of `OpenMP`:idx: and as
  ## such isn't aware of the parallelism in your code! Be careful! Later
  ## versions of `||` will get proper support by Nim's code generator
  ## and GC.
  discard

iterator `||`*[S, T](a: S, b: T, step: Positive, annotation: static string = "parallel for"): T {.
  inline, magic: "OmpParFor", sideEffect.} =
  ## OpenMP parallel loop iterator with stepping.
  ## Same as `countup` but the loop may run in parallel.
  ##
  ## `annotation` is an additional annotation for the code generator to use.
  ## The default annotation is `parallel for`.
  ## Please refer to the `OpenMP Syntax Reference
  ## <https://www.openmp.org/wp-content/uploads/OpenMP-4.5-1115-CPP-web.pdf>`_
  ## for further information.
  ##
  ## Note that the compiler maps that to
  ## the `#pragma omp parallel for` construct of `OpenMP`:idx: and as
  ## such isn't aware of the parallelism in your code! Be careful! Later
  ## versions of `||` will get proper support by Nim's code generator
  ## and GC.
  discard
