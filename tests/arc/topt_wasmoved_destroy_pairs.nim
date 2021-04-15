discard """
  output: ''''''
  cmd: '''nim c --gc:arc --expandArc:main --expandArc:tfor --hint:Performance:off $file'''
  nimout: '''--expandArc: main

var
  a
  b
  x
x = f()
if cond:
  add(a):
    let blitTmp = x
    blitTmp
else:
  add(b):
    let blitTmp_1 = x
    blitTmp_1
`=destroy`(b)
`=destroy`(a)
-- end of expandArc ------------------------
--expandArc: tfor

var
  a
  b
  x
try:
  x = f()
  block :tmp:
    var i_cursor
    block :tmp_1:
      var i_1_cursor
      var :tmp_2
      :tmp_2 = 3
      if 0 <= int(:tmp_2):
        block :tmp_3:
          var i_2
          mixin inc
          mixin <
          var avalue = 0
          var bvalue = int(:tmp_2)
          var yieldedValue = addr(avalue)
          var stepvalue: int = 1
          if (
            bvalue < avalue):
            swap(avalue, bvalue)
            yieldedValue = addr(bvalue)
            stepvalue = -stepvalue
          block :tmp_4:
            while avalue <= bvalue:
              var :tmpD
              i_2 = T(yieldedValue[])
              i_1_cursor = i_2
              i_cursor = i_1_cursor
              if i_cursor == 2:
                return
              add(a):
                wasMoved(:tmpD)
                `=copy`(:tmpD, x)
                :tmpD
              inc(yieldedValue[], stepvalue)
  if cond:
    add(a):
      let blitTmp = x
      wasMoved(x)
      blitTmp
  else:
    add(b):
      let blitTmp_1 = x
      wasMoved(x)
      blitTmp_1
finally:
  `=destroy`(x)
  `=destroy_1`(b)
  `=destroy_1`(a)
-- end of expandArc ------------------------'''
"""

proc f(): seq[int] =
  @[1, 2, 3]

proc main(cond: bool) =
  var a, b: seq[seq[int]]
  var x = f()
  if cond:
    a.add x
  else:
    b.add x

# all paths move 'x' so no wasMoved(x); destroy(x) pair should be left in the
# AST.

main(false)


proc tfor(cond: bool) =
  var a, b: seq[seq[int]]

  var x = f()

  for i in 0 ..< 4:
    if i == 2: return
    a.add x

  if cond:
    a.add x
  else:
    b.add x

tfor(false)
