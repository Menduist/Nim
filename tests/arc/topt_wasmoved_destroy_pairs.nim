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
    let avalue = 0
    let bvalue = 4
    if avalue < bvalue:
      block :tmp_1:
        var i_1_cursor
        var :tmp_2
        :tmp_2 = 3
        let avalue_1 = 0
        let bvalue_1 = typeof(avalue_2)(:tmp_2)
        if avalue_1 <= bvalue_1:
          block :tmp_3:
            var i_2
            mixin inc
            mixin <
            var avalue_3 = 0
            var bvalue_2 = typeof(avalue_4)(:tmp_2)
            var yieldedValue = addr(avalue_3)
            var stepvalue: int = 1
            if (
              bvalue_2 < avalue_3):
              swap(avalue_3, bvalue_2)
              yieldedValue = addr(bvalue_2)
              stepvalue = -stepvalue
            block :tmp_4:
              while avalue_3 <= bvalue_2:
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
