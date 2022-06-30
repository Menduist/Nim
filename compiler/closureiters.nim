#
#
#           The Nim Compiler
#        (c) Copyright 2018 Nim Contributors
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

# This file implements closure iterator transformations.
# The main idea is to split the closure iterator body to top level statements.
# The body is split by yield statement.
#
# Example:
#  while a > 0:
#    echo "hi"
#    yield a
#    dec a
#
# Should be transformed to:
#  STATE0:
#    if a > 0:
#      echo "hi"
#      :state = 1 # Next state
#      return a # yield
#    else:
#      :state = 2 # Next state
#      break :stateLoop # Proceed to the next state
#  STATE1:
#    dec a
#    :state = 0 # Next state
#    break :stateLoop # Proceed to the next state
#  STATE2:
#    :state = -1 # End of execution

# The transformation should play well with lambdalifting, however depending
# on situation, it can be called either before or after lambdalifting
# transformation. As such we behave slightly differently, when accessing
# iterator state, or using temp variables. If lambdalifting did not happen,
# we just create local variables, so that they will be lifted further on.
# Otherwise, we utilize existing env, created by lambdalifting.

# Lambdalifting treats :state variable specially, it should always end up
# as the first field in env. Currently C codegen depends on this behavior.

# One special subtransformation is nkStmtListExpr lowering.
# Example:
#   template foo(): int =
#     yield 1
#     2
#
#   iterator it(): int {.closure.} =
#     if foo() == 2:
#       yield 3
#
# If a nkStmtListExpr has yield inside, it has first to be lowered to:
#   yield 1
#   :tmpSlLower = 2
#   if :tmpSlLower == 2:
#     yield 3

# nkTryStmt Transformations:
# If the iter has an nkTryStmt with a yield inside
#  - the closure iter is promoted to have exceptions (ctx.hasExceptions = true)
#  - exception table is created. This is a const array, where
#    `abs(exceptionTable[i])` is a state idx to which we should jump from state
#    `i` should exception be raised in state `i`. For all states in `try` block
#    the target state is `except` block. For all states in `except` block
#    the target state is `finally` block. For all other states there is no
#    target state (0, as the first block can never be neither except nor finally).
#    `exceptionTable[i]` is < 0 if `abs(exceptionTable[i])` is except block,
#    and > 0, for finally block.
#  - local variable :curExc is created
#  - the iter body is wrapped into a
#      try:
#       closureIterSetupExc(:curExc)
#       ...body...
#      catch:
#        :state = exceptionTable[:state]
#        if :state == 0: raise # No state that could handle exception
#        :unrollFinally = :state > 0 # Target state is finally
#        if :state < 0:
#           :state = -:state
#        :curExc = getCurrentException()
#
# nkReturnStmt within a try/except/finally now has to behave differently as we
# want the nearest finally block to be executed before the return, thus it is
# transformed to:
#  :tmpResult = returnValue (if return doesn't have a value, this is skipped)
#  :unrollFinally = true
#  goto nearestFinally (or -1 if not exists)
#
# Example:
#
# try:
#  yield 0
#  raise ...
# except:
#  yield 1
#  return 3
# finally:
#  yield 2
#
# Is transformed to (yields are left in place for example simplicity,
#    in reality the code is subdivided even more, as described above):
#
# STATE0: # Try
#   yield 0
#   raise ...
#   :state = 2 # What would happen should we not raise
#   break :stateLoop
# STATE1: # Except
#   yield 1
#   :tmpResult = 3           # Return
#   :unrollFinally = true # Return
#   :state = 2 # Goto Finally
#   break :stateLoop
#   :state = 2 # What would happen should we not return
#   break :stateLoop
# STATE2: # Finally
#   yield 2
#   if :unrollFinally: # This node is created by `newEndFinallyNode`
#     if :curExc.isNil:
#       return :tmpResult
#     else:
#       closureIterSetupExc(nil)
#       raise
#   state = -1 # Goto next state. In this case we just exit
#   break :stateLoop

import
  ast, msgs, idents,
  renderer, magicsys, lowerings, lambdalifting, modulegraphs, lineinfos,
  tables, options

when defined(nimPreviewSlimSystem):
  import std/assertions

type
  BreakableScope = tuple
    outState: PNode
    nearestFinally: PNode

  Ctx = object
    g: ModuleGraph
    fn: PSym
    stateVarSym: PSym # :state variable. nil if env already introduced by lambdalifting
    tmpResultSym: PSym # Used when we return, but finally has to interfere
    unrollFinallySym: PSym # Indicates that we're unrolling finally states (either exception happened or premature return)
    unrollUntilSym: PSym
    afterUnrollSym: PSym
    curExcSym: PSym # Current exception

    states: seq[PNode] # The resulting states. Every state is an nkState node.
    stateLoopLabel: PSym # Label to break on, when jumping between states.
    exitState: PNode # index of the last state
    tempVarId: int # unique name counter
    tempVars: PNode # Temp var decls, nkVarSection
    hasExceptions: bool # Does closure have yield in try?
    curExcHandlingState: PNode # Negative for except, positive for finally
    nearestFinally: PNode # Index of the nearest finally block. For try/except it
                    # is their finally. For finally it is parent finally. Otherwise nil
    breakableScopes: Table[int, BreakableScope] # Maps a block label to it's data
    idgen: IdGenerator

const
  nkSkip = {nkEmpty..nkNilLit, nkTemplateDef, nkTypeSection, nkStaticStmt,
            nkCommentStmt, nkMixinStmt, nkBindStmt} + procDefs

proc newStateAccess(ctx: var Ctx): PNode =
  if ctx.stateVarSym.isNil:
    result = rawIndirectAccess(newSymNode(getEnvParam(ctx.fn)),
        getStateField(ctx.g, ctx.fn), ctx.fn.info)
  else:
    result = newSymNode(ctx.stateVarSym)

proc newStateAssgn(ctx: var Ctx, toValue: PNode): PNode =
  # Creates state assignment:
  #   :state = toValue
  newTree(nkAsgn, ctx.newStateAccess(), toValue)

proc newStateAssgn(ctx: var Ctx, stateNo: int = -2): PNode =
  # Creates state assignment:
  #   :state = stateNo
  ctx.newStateAssgn(newIntTypeNode(stateNo, ctx.g.getSysType(TLineInfo(), tyInt)))

proc newEnvVar(ctx: var Ctx, name: string, typ: PType): PSym =
  result = newSym(skVar, getIdent(ctx.g.cache, name), nextSymId(ctx.idgen), ctx.fn, ctx.fn.info)
  result.typ = typ
  assert(not typ.isNil)

  if not ctx.stateVarSym.isNil:
    # We haven't gone through labmda lifting yet, so just create a local var,
    # it will be lifted later
    if ctx.tempVars.isNil:
      ctx.tempVars = newNodeI(nkVarSection, ctx.fn.info)
      addVar(ctx.tempVars, newSymNode(result))
  else:
    let envParam = getEnvParam(ctx.fn)
    # let obj = envParam.typ.lastSon
    result = addUniqueField(envParam.typ.lastSon, result, ctx.g.cache, ctx.idgen)

proc newEnvVarAccess(ctx: Ctx, s: PSym): PNode =
  if ctx.stateVarSym.isNil:
    result = rawIndirectAccess(newSymNode(getEnvParam(ctx.fn)), s, ctx.fn.info)
  else:
    result = newSymNode(s)

proc hasReturnType(ctx: var Ctx): bool =
  not(isNil(ctx.fn.typ[0]))

proc newTmpResultAccess(ctx: var Ctx): PNode =
  doAssert(ctx.hasReturnType)
  if ctx.tmpResultSym.isNil:
    ctx.tmpResultSym = ctx.newEnvVar(":tmpResult", ctx.fn.typ[0])
  ctx.newEnvVarAccess(ctx.tmpResultSym)

proc newUnrollFinallyAccess(ctx: var Ctx, info: TLineInfo): PNode =
  if ctx.unrollFinallySym.isNil:
    ctx.unrollFinallySym = ctx.newEnvVar(":unrollFinally", ctx.g.getSysType(info, tyBool))
  ctx.newEnvVarAccess(ctx.unrollFinallySym)

proc newUnrollUntilAccess(ctx: var Ctx, info: TLineInfo): PNode =
  if ctx.unrollUntilSym.isNil:
    ctx.unrollUntilSym = ctx.newEnvVar(":unrollUntil", ctx.g.getSysType(info, tyInt))
  ctx.newEnvVarAccess(ctx.unrollUntilSym)

proc newAfterUnrollAccess(ctx: var Ctx, info: TLineInfo): PNode =
  if ctx.afterUnrollSym.isNil:
    ctx.afterUnrollSym = ctx.newEnvVar(":afterUnroll", ctx.g.getSysType(info, tyInt))
  ctx.newEnvVarAccess(ctx.afterUnrollSym)

proc newCurExcAccess(ctx: var Ctx): PNode =
  if ctx.curExcSym.isNil:
    ctx.curExcSym = ctx.newEnvVar(":curExc", ctx.g.callCodegenProc("getCurrentException").typ)
  ctx.newEnvVarAccess(ctx.curExcSym)

proc newState(ctx: var Ctx, stateBody: PNode): PNode =
  # Creates a new state, adds it to the context fills out `gotoOut` so that it
  # will goto this state.
  # Returns index of the newly created state

  # Will get his real index as a last step
  let resLit = ctx.g.newIntLit(stateBody.info, ctx.states.len + 10000)
  result = newNodeI(nkState, stateBody.info)
  result.add(resLit)
  result.add(stateBody)
  if isNil(ctx.curExcHandlingState):
    result.add(newNodeI(nkEmpty, stateBody.info))
  else:
    result.add(ctx.curExcHandlingState)
  ctx.states.add(result)

proc toStmtList(n: PNode): PNode =
  result = n
  if result.kind notin {nkStmtList, nkStmtListExpr}:
    result = newNodeI(nkStmtList, n.info)
    result.add(n)

proc gotoState(state: PNode): PNode =
  assert state.kind == nkState
  assert state[0].kind == nkIntLit
  result = newTree(nkGotoState, state[0])

proc addGotoOut(n: PNode, outState: PNode): PNode =
  # Make sure `n` is a stmtlist, and ends with `gotoOut`
  result = toStmtList(n)
  if result.len == 0 or result[^1].kind != nkGotoState:
    result.add(gotoState(outState))

proc newTempVar(ctx: var Ctx, typ: PType): PSym =
  result = ctx.newEnvVar(":tmpSlLower" & $ctx.tempVarId, typ)
  inc ctx.tempVarId

proc hasYields(n: PNode): bool =
  # TODO: This is very inefficient. It traverses the node, looking for nkYieldStmt.
  case n.kind
  of nkYieldStmt:
    result = true
  of nkSkip:
    discard
  else:
    for c in n:
      if c.hasYields:
        result = true
        break

proc hasControlFlow(n: PNode): bool =
  # TODO: This is very inefficient. It traverses the node, looking for nkYieldStmt.
  case n.kind
  of nkYieldStmt, nkBreakStmt:
    result = true
  of nkSkip:
    discard
  else:
    for c in n:
      if c.hasControlFlow:
        result = true
        break

proc newNullifyCurExc(ctx: var Ctx, info: TLineInfo): PNode =
  # :curEcx = nil
  let curExc = ctx.newCurExcAccess()
  curExc.info = info
  let nilnode = newNode(nkNilLit)
  nilnode.typ = curExc.typ
  result = newTree(nkAsgn, curExc, nilnode)

proc newOr(g: ModuleGraph, a, b: PNode): PNode {.inline.} =
  result = newTree(nkCall, newSymNode(g.getSysMagic(a.info, "or", mOr)), a, b)
  result.typ = g.getSysType(a.info, tyBool)
  result.info = a.info

proc collectExceptState(ctx: var Ctx, n: PNode): PNode {.inline.} =
  var ifStmt = newNodeI(nkIfStmt, n.info)
  let g = ctx.g
  for c in n:
    if c.kind == nkExceptBranch:
      var ifBranch: PNode

      if c.len > 1:
        var cond: PNode
        for i in 0..<c.len - 1:
          assert(c[i].kind == nkType)
          let nextCond = newTree(nkCall,
            newSymNode(g.getSysMagic(c.info, "of", mOf)),
            g.callCodegenProc("getCurrentException"),
            c[i])
          nextCond.typ = ctx.g.getSysType(c.info, tyBool)
          nextCond.info = c.info

          if cond.isNil:
            cond = nextCond
          else:
            cond = g.newOr(cond, nextCond)

        ifBranch = newNodeI(nkElifBranch, c.info)
        ifBranch.add(cond)
      else:
        if ifStmt.len == 0:
          ifStmt = newNodeI(nkStmtList, c.info)
          ifBranch = newNodeI(nkStmtList, c.info)
        else:
          ifBranch = newNodeI(nkElse, c.info)

      ifBranch.add(c[^1])
      ifStmt.add(ifBranch)

  if ifStmt.len != 0:
    result = newTree(nkStmtList, ctx.newNullifyCurExc(n.info), ifStmt)
  else:
    result = ctx.g.emptyNode

proc addElseToExcept(ctx: var Ctx, n: PNode) =
  if n.kind == nkStmtList and n[1].kind == nkIfStmt and n[1][^1].kind != nkElse:
    # Not all cases are covered
    let branchBody = newNodeI(nkStmtList, n.info)

    block: # :unrollFinally = true
      branchBody.add(newTree(nkAsgn,
        ctx.newUnrollFinallyAccess(n.info),
        newIntTypeNode(1, ctx.g.getSysType(n.info, tyBool))))
      branchBody.add(newTree(nkAsgn, ctx.newUnrollUntilAccess(n.info), newIntTypeNode(-1, ctx.g.getSysType(n.info, tyInt))))

    block: # :curExc = getCurrentException()
      branchBody.add(newTree(nkAsgn,
        ctx.newCurExcAccess(),
        ctx.g.callCodegenProc("getCurrentException")))

    block: # goto nearestFinally
      branchBody.add(newTree(nkGotoState, ctx.nearestFinally))

    let elseBranch = newTree(nkElse, branchBody)
    n[1].add(elseBranch)

proc getFinallyNode(ctx: var Ctx, n: PNode): PNode =
  result = n[^1]
  if result.kind == nkFinally:
    result = result[0]
  else:
    result = ctx.g.emptyNode

proc hasYieldsInExpressions(n: PNode): bool =
  case n.kind
  of nkSkip:
    discard
  of nkStmtListExpr:
    if isEmptyType(n.typ):
      for c in n:
        if c.hasYieldsInExpressions:
          return true
    else:
      result = n.hasYields
  of nkCast:
    for i in 1..<n.len:
      if n[i].hasYieldsInExpressions:
        return true
  else:
    for c in n:
      if c.hasYieldsInExpressions:
        return true

proc exprToStmtList(n: PNode): tuple[s, res: PNode] =
  assert(n.kind == nkStmtListExpr)
  result.s = newNodeI(nkStmtList, n.info)
  result.s.sons = @[]

  var n = n
  while n.kind == nkStmtListExpr:
    result.s.sons.add(n.sons)
    result.s.sons.setLen(result.s.len - 1) # delete last son
    n = n[^1]

  result.res = n

proc newEnvVarAsgn(ctx: Ctx, s: PSym, v: PNode): PNode =
  if isEmptyType(v.typ):
    result = v
  else:
    result = newTree(nkFastAsgn, ctx.newEnvVarAccess(s), v)
    result.info = v.info

proc addExprAssgn(ctx: Ctx, output, input: PNode, sym: PSym) =
  if input.kind == nkStmtListExpr:
    let (st, res) = exprToStmtList(input)
    output.add(st)
    output.add(ctx.newEnvVarAsgn(sym, res))
  else:
    output.add(ctx.newEnvVarAsgn(sym, input))

proc convertExprBodyToAsgn(ctx: Ctx, exprBody: PNode, res: PSym): PNode =
  result = newNodeI(nkStmtList, exprBody.info)
  ctx.addExprAssgn(result, exprBody, res)

proc newNotCall(g: ModuleGraph; e: PNode): PNode =
  result = newTree(nkCall, newSymNode(g.getSysMagic(e.info, "not", mNot), e.info), e)
  result.typ = g.getSysType(e.info, tyBool)

proc lowerStmtListExprs(ctx: var Ctx, n: PNode, needsSplit: var bool): PNode =
  result = n
  case n.kind
  of nkSkip:
    discard

  of nkYieldStmt:
    var ns = false
    for i in 0..<n.len:
      n[i] = ctx.lowerStmtListExprs(n[i], ns)

    if ns:
      result = newNodeI(nkStmtList, n.info)
      let (st, ex) = exprToStmtList(n[0])
      result.add(st)
      n[0] = ex
      result.add(n)

    needsSplit = true

  of nkPar, nkObjConstr, nkTupleConstr, nkBracket:
    var ns = false
    for i in 0..<n.len:
      n[i] = ctx.lowerStmtListExprs(n[i], ns)

    if ns:
      needsSplit = true

      result = newNodeI(nkStmtListExpr, n.info)
      if n.typ.isNil: internalError(ctx.g.config, "lowerStmtListExprs: constr typ.isNil")
      result.typ = n.typ

      for i in 0..<n.len:
        case n[i].kind
        of nkExprColonExpr:
          if n[i][1].kind == nkStmtListExpr:
            let (st, ex) = exprToStmtList(n[i][1])
            result.add(st)
            n[i][1] = ex
        of nkStmtListExpr:
          let (st, ex) = exprToStmtList(n[i])
          result.add(st)
          n[i] = ex
        else: discard
      result.add(n)

  of nkIfStmt, nkIfExpr:
    var ns = false
    for i in 0..<n.len:
      n[i] = ctx.lowerStmtListExprs(n[i], ns)

    if ns:
      needsSplit = true
      var tmp: PSym
      let isExpr = not isEmptyType(n.typ)
      if isExpr:
        tmp = ctx.newTempVar(n.typ)
        result = newNodeI(nkStmtListExpr, n.info)
        result.typ = n.typ
      else:
        result = newNodeI(nkStmtList, n.info)

      var curS = result

      for branch in n:
        case branch.kind
        of nkElseExpr, nkElse:
          if isExpr:
            let branchBody = newNodeI(nkStmtList, branch.info)
            ctx.addExprAssgn(branchBody, branch[0], tmp)
            let newBranch = newTree(nkElse, branchBody)
            curS.add(newBranch)
          else:
            curS.add(branch)

        of nkElifExpr, nkElifBranch:
          var newBranch: PNode
          if branch[0].kind == nkStmtListExpr:
            let (st, res) = exprToStmtList(branch[0])
            let elseBody = newTree(nkStmtList, st)

            newBranch = newTree(nkElifBranch, res, branch[1])

            let newIf = newTree(nkIfStmt, newBranch)
            elseBody.add(newIf)
            if curS.kind == nkIfStmt:
              let newElse = newNodeI(nkElse, branch.info)
              newElse.add(elseBody)
              curS.add(newElse)
            else:
              curS.add(elseBody)
            curS = newIf
          else:
            newBranch = branch
            if curS.kind == nkIfStmt:
              curS.add(newBranch)
            else:
              let newIf = newTree(nkIfStmt, newBranch)
              curS.add(newIf)
              curS = newIf

          if isExpr:
            let branchBody = newNodeI(nkStmtList, branch[1].info)
            ctx.addExprAssgn(branchBody, branch[1], tmp)
            newBranch[1] = branchBody

        else:
          internalError(ctx.g.config, "lowerStmtListExpr(nkIf): " & $branch.kind)

      if isExpr: result.add(ctx.newEnvVarAccess(tmp))

  of nkTryStmt, nkHiddenTryStmt:
    var ns = false
    for i in 0..<n.len:
      n[i] = ctx.lowerStmtListExprs(n[i], ns)

    if ns:
      needsSplit = true
      let isExpr = not isEmptyType(n.typ)

      if isExpr:
        result = newNodeI(nkStmtListExpr, n.info)
        result.typ = n.typ
        let tmp = ctx.newTempVar(n.typ)

        n[0] = ctx.convertExprBodyToAsgn(n[0], tmp)
        for i in 1..<n.len:
          let branch = n[i]
          case branch.kind
          of nkExceptBranch:
            if branch[0].kind == nkType:
              branch[1] = ctx.convertExprBodyToAsgn(branch[1], tmp)
            else:
              branch[0] = ctx.convertExprBodyToAsgn(branch[0], tmp)
          of nkFinally:
            discard
          else:
            internalError(ctx.g.config, "lowerStmtListExpr(nkTryStmt): " & $branch.kind)
        result.add(n)
        result.add(ctx.newEnvVarAccess(tmp))

  of nkCaseStmt:
    var ns = false
    for i in 0..<n.len:
      n[i] = ctx.lowerStmtListExprs(n[i], ns)

    if ns:
      needsSplit = true

      let isExpr = not isEmptyType(n.typ)

      if isExpr:
        let tmp = ctx.newTempVar(n.typ)
        result = newNodeI(nkStmtListExpr, n.info)
        result.typ = n.typ

        if n[0].kind == nkStmtListExpr:
          let (st, ex) = exprToStmtList(n[0])
          result.add(st)
          n[0] = ex

        for i in 1..<n.len:
          let branch = n[i]
          case branch.kind
          of nkOfBranch:
            branch[^1] = ctx.convertExprBodyToAsgn(branch[^1], tmp)
          of nkElse:
            branch[0] = ctx.convertExprBodyToAsgn(branch[0], tmp)
          else:
            internalError(ctx.g.config, "lowerStmtListExpr(nkCaseStmt): " & $branch.kind)
        result.add(n)
        result.add(ctx.newEnvVarAccess(tmp))
      elif n[0].kind == nkStmtListExpr:
        result = newNodeI(nkStmtList, n.info)
        let (st, ex) = exprToStmtList(n[0])
        result.add(st)
        n[0] = ex
        result.add(n)

  of nkCallKinds, nkChckRange, nkChckRangeF, nkChckRange64:
    var ns = false
    for i in 0..<n.len:
      n[i] = ctx.lowerStmtListExprs(n[i], ns)

    if ns:
      needsSplit = true
      let isExpr = not isEmptyType(n.typ)

      if isExpr:
        result = newNodeI(nkStmtListExpr, n.info)
        result.typ = n.typ
      else:
        result = newNodeI(nkStmtList, n.info)

      if n[0].kind == nkSym and n[0].sym.magic in {mAnd, mOr}: # `and`/`or` short cirquiting
        var cond = n[1]
        if cond.kind == nkStmtListExpr:
          let (st, ex) = exprToStmtList(cond)
          result.add(st)
          cond = ex

        let tmp = ctx.newTempVar(cond.typ)
        result.add(ctx.newEnvVarAsgn(tmp, cond))

        var check = ctx.newEnvVarAccess(tmp)
        if n[0].sym.magic == mOr:
          check = ctx.g.newNotCall(check)

        cond = n[2]
        let ifBody = newNodeI(nkStmtList, cond.info)
        if cond.kind == nkStmtListExpr:
          let (st, ex) = exprToStmtList(cond)
          ifBody.add(st)
          cond = ex
        ifBody.add(ctx.newEnvVarAsgn(tmp, cond))

        let ifBranch = newTree(nkElifBranch, check, ifBody)
        let ifNode = newTree(nkIfStmt, ifBranch)
        result.add(ifNode)
        result.add(ctx.newEnvVarAccess(tmp))
      else:
        for i in 0..<n.len:
          if n[i].kind == nkStmtListExpr:
            let (st, ex) = exprToStmtList(n[i])
            result.add(st)
            n[i] = ex

          if n[i].kind in nkCallKinds: # XXX: This should better be some sort of side effect tracking
            let tmp = ctx.newTempVar(n[i].typ)
            result.add(ctx.newEnvVarAsgn(tmp, n[i]))
            n[i] = ctx.newEnvVarAccess(tmp)

        result.add(n)

  of nkVarSection, nkLetSection:
    result = newNodeI(nkStmtList, n.info)
    for c in n:
      let varSect = newNodeI(n.kind, n.info)
      varSect.add(c)
      var ns = false
      c[^1] = ctx.lowerStmtListExprs(c[^1], ns)
      if ns:
        needsSplit = true
        let (st, ex) = exprToStmtList(c[^1])
        result.add(st)
        c[^1] = ex
      result.add(varSect)

  of nkDiscardStmt, nkReturnStmt, nkRaiseStmt:
    var ns = false
    for i in 0..<n.len:
      n[i] = ctx.lowerStmtListExprs(n[i], ns)

    if ns:
      needsSplit = true
      result = newNodeI(nkStmtList, n.info)
      let (st, ex) = exprToStmtList(n[0])
      result.add(st)
      n[0] = ex
      result.add(n)

  of nkCast, nkHiddenStdConv, nkHiddenSubConv, nkConv, nkObjDownConv,
      nkDerefExpr, nkHiddenDeref:
    var ns = false
    for i in ord(n.kind == nkCast)..<n.len:
      n[i] = ctx.lowerStmtListExprs(n[i], ns)

    if ns:
      needsSplit = true
      result = newNodeI(nkStmtListExpr, n.info)
      result.typ = n.typ
      let (st, ex) = exprToStmtList(n[^1])
      result.add(st)
      n[^1] = ex
      result.add(n)

  of nkAsgn, nkFastAsgn:
    var ns = false
    for i in 0..<n.len:
      n[i] = ctx.lowerStmtListExprs(n[i], ns)

    if ns:
      needsSplit = true
      result = newNodeI(nkStmtList, n.info)
      if n[0].kind == nkStmtListExpr:
        let (st, ex) = exprToStmtList(n[0])
        result.add(st)
        n[0] = ex

      if n[1].kind == nkStmtListExpr:
        let (st, ex) = exprToStmtList(n[1])
        result.add(st)
        n[1] = ex

      result.add(n)

  of nkBracketExpr:
    var lhsNeedsSplit = false
    var rhsNeedsSplit = false
    n[0] = ctx.lowerStmtListExprs(n[0], lhsNeedsSplit)
    n[1] = ctx.lowerStmtListExprs(n[1], rhsNeedsSplit)
    if lhsNeedsSplit or rhsNeedsSplit:
      needsSplit = true
      result = newNodeI(nkStmtListExpr, n.info)
      if lhsNeedsSplit:
        let (st, ex) = exprToStmtList(n[0])
        result.add(st)
        n[0] = ex

      if rhsNeedsSplit:
        let (st, ex) = exprToStmtList(n[1])
        result.add(st)
        n[1] = ex
      result.add(n)

  of nkWhileStmt:
    var condNeedsSplit = false
    n[0] = ctx.lowerStmtListExprs(n[0], condNeedsSplit)
    var bodyNeedsSplit = false
    n[1] = ctx.lowerStmtListExprs(n[1], bodyNeedsSplit)

    if condNeedsSplit or bodyNeedsSplit:
      needsSplit = true

      if condNeedsSplit:
        # need to wrap in a block to allow named breaking
        let blockSym = newSymNode(newSym(skVar, getIdent(ctx.g.cache, "breaker"), nextSymId(ctx.idgen), ctx.fn, ctx.fn.info))
        let (st, ex) = exprToStmtList(n[0])
        let brk = newTree(nkBreakStmt, blockSym)
        let branch = newTree(nkElifBranch, ctx.g.newNotCall(ex), brk)
        let check = newTree(nkIfStmt, branch)
        let newBody = newTree(nkStmtList, st, check, n[1])

        n[0] = newSymNode(ctx.g.getSysSym(n[0].info, "true"))
        n[1] = newBody
        result = newTree(
          nkBlockStmt,
          blockSym,
          newTree(nkWhileStmt,
            newSymNode(ctx.g.getSysSym(n[0].info, "true")),
            newBody)
        )

  of nkDotExpr, nkCheckedFieldExpr:
    var ns = false
    n[0] = ctx.lowerStmtListExprs(n[0], ns)
    if ns:
      needsSplit = true
      result = newNodeI(nkStmtListExpr, n.info)
      result.typ = n.typ
      let (st, ex) = exprToStmtList(n[0])
      result.add(st)
      n[0] = ex
      result.add(n)

  of nkBlockExpr:
    var ns = false
    n[1] = ctx.lowerStmtListExprs(n[1], ns)
    if ns:
      needsSplit = true
      result = newNodeI(nkStmtListExpr, n.info)
      result.typ = n.typ
      let (st, ex) = exprToStmtList(n[1])
      n.transitionSonsKind(nkBlockStmt)
      n.typ = nil
      n[1] = st
      result.add(n)
      result.add(ex)

  else:
    for i in 0..<n.len:
      n[i] = ctx.lowerStmtListExprs(n[i], needsSplit)

proc newEndFinallyNode(ctx: var Ctx, info: TLineInfo): PNode =
  # Generate the following code:
  #   if :unrollFinally:
  #       if :curExc.isNil:
  #         return :tmpResult
  #       else:
  #         raise
  let curExc = ctx.newCurExcAccess()
  let nilnode = newNode(nkNilLit)
  nilnode.typ = curExc.typ
  let cmp = newTree(nkCall, newSymNode(ctx.g.getSysMagic(info, "==", mEqRef), info), curExc, nilnode)
  cmp.typ = ctx.g.getSysType(info, tyBool)

  let asgn =
    if ctx.hasReturnType:
      newTree(nkFastAsgn,
        newSymNode(getClosureIterResult(ctx.g, ctx.fn, ctx.idgen), info),
        ctx.newTmpResultAccess())
    else:
      newTree(nkEmpty)

  let retStmt = newTree(nkReturnStmt, asgn)
  let branch = newTree(nkElifBranch, cmp, retStmt)

  let nullifyExc = newTree(nkCall, newSymNode(ctx.g.getCompilerProc("closureIterSetupExc")), nilnode)
  nullifyExc.info = info
  let raiseStmt = newTree(nkRaiseStmt, curExc)
  raiseStmt.info = info
  let elseBranch = newTree(nkElse, newTree(nkStmtList, nullifyExc, raiseStmt))

  let nearestFinallyIdx =
    if isNil(ctx.nearestFinally):
      newIntTypeNode(0, ctx.g.getSysType(info, tyInt))
    else:
      ctx.nearestFinally
  let cmp1 = newTree(nkCall, newSymNode(ctx.g.getSysMagic(info, "==", mEqRef), info), ctx.newUnrollUntilAccess(info), nearestFinallyIdx)
  cmp1.typ = ctx.g.getSysType(info, tyBool)
  let bod1 =
    newTree(nkStmtList,
      newTree(nkAsgn, ctx.newUnrollFinallyAccess(info), newIntTypeNode(0, ctx.g.getSysType(info, tyBool))),
      newTree(nkAsgn, ctx.newUnrollUntilAccess(info), newIntTypeNode(-1, ctx.g.getSysType(info, tyInt))),
      newTree(nkGotoState, ctx.newAfterUnrollAccess(info))
    )

  let ifBody = newTree(nkStmtList,
    newTree(nkIfStmt, newTree(nkElifBranch, cmp1, bod1)),
    newTree(nkIfStmt, branch, elseBranch)
  )
  let elifBranch = newTree(nkElifBranch, ctx.newUnrollFinallyAccess(info), ifBody)
  elifBranch.info = info

  result = newTree(nkIfStmt, elifBranch)

proc transformReturnsInTry(ctx: var Ctx, n: PNode): PNode =
  result = n
  case n.kind
  of nkReturnStmt:
    # We're somewhere in try, transform to finally unrolling
    assert(not isNil(ctx.nearestFinally))

    result = newNodeI(nkStmtList, n.info)

    block: # :unrollFinally = true
      let asgn = newNodeI(nkAsgn, n.info)
      asgn.add(ctx.newUnrollFinallyAccess(n.info))
      asgn.add(newIntTypeNode(1, ctx.g.getSysType(n.info, tyBool)))
      result.add(asgn)
      result.add(newTree(nkAsgn, ctx.newUnrollUntilAccess(n.info), newIntTypeNode(-1, ctx.g.getSysType(n.info, tyInt))))

    if n[0].kind != nkEmpty:
      let asgnTmpResult = newNodeI(nkAsgn, n.info)
      asgnTmpResult.add(ctx.newTmpResultAccess())
      let x = if n[0].kind in {nkAsgn, nkFastAsgn}: n[0][1] else: n[0]
      asgnTmpResult.add(x)
      result.add(asgnTmpResult)

    result.add(ctx.newNullifyCurExc(n.info))

    let goto = newTree(nkGotoState, ctx.nearestFinally)
    result.add(goto)

  of nkSkip:
    discard
  else:
    for i in 0..<n.len:
      n[i] = ctx.transformReturnsInTry(n[i])

proc transformClosureIteratorBody(ctx: var Ctx, n: PNode, outState: PNode): PNode =
  result = n

  case n.kind
  of nkSkip: discard

  of nkStmtList, nkStmtListExpr:
    result = addGotoOut(result, outState)
    for i in 0..<n.len:
      if n[i].hasControlFlow:
        # Create a new split

        # Move the rest of the list to a new state
        let s = newNodeI(nkStmtList, n[i + 1].info)
        for j in i + 1..<n.len:
          s.add(n[j])
        n.sons.setLen(i + 1)
        let subOutState = ctx.newState(s)

        # Process this element, with the rest of the list as out state
        n[i] = ctx.transformClosureIteratorBody(n[i], subOutState)

        # Process the rest of the list
        if ctx.transformClosureIteratorBody(s, outState) != s:
          internalError(ctx.g.config, "transformClosureIteratorBody != s")
        break

  of nkYieldStmt:
    result = newNodeI(nkStmtList, n.info)
    result.add(n)
    result = result.addGotoOut(outState)

  of nkElse, nkElseExpr:
    result[0] = addGotoOut(result[0], outState)
    result[0] = ctx.transformClosureIteratorBody(result[0], outState)

  of nkElifBranch, nkElifExpr, nkOfBranch:
    result[^1] = addGotoOut(result[^1], outState)
    result[^1] = ctx.transformClosureIteratorBody(result[^1], outState)

  of nkIfStmt, nkCaseStmt:
    for i in 0..<n.len:
      n[i] = ctx.transformClosureIteratorBody(n[i], outState)
    if n[^1].kind != nkElse:
      # We don't have an else branch, but every possible branch has to end with
      # gotoOut, so add else here.
      let elseBranch = newTree(nkElse, gotoState(outState))
      n.add(elseBranch)

  of nkWhileStmt:
    # while e:
    #   s
    # ->
    # BEGIN_STATE:
    #   if e:
    #     s
    #     goto BEGIN_STATE
    #   else:
    #     goto OUT

    let beginStateBody = newNodeI(nkStmtList, n.info)
    let beginState = ctx.newState(beginStateBody)

    let ifNode = newTree(
      nkIfStmt,
      newTree(nkElifBranch,
        n[0],
        ctx.transformClosureIteratorBody(addGotoOut(n[1], beginState), result)),
      newTree(nkElse, gotoState(outState))
    )
    beginStateBody.add(ifNode)
    result = gotoState(beginState)

  of nkBlockStmt:
    let symId = n[0].sym.id
    ctx.breakableScopes[symId] = (outState, ctx.nearestFinally)

    result = ctx.transformClosureIteratorBody(n[1], outState)

  of nkBreakStmt:
    result = newNodeI(nkStmtList, n.info)
    let
      symId = n[0].sym.id
      breakableCtx = ctx.breakableScopes[symId]
    if breakableCtx.nearestFinally == ctx.nearestFinally:
      # No finally in the block, let's just break it
      result.add(gotoState(breakableCtx.outState))
    else:
      # Partial unroll
      result.add(newTree(nkAsgn, ctx.newUnrollFinallyAccess(n.info), newIntTypeNode(1, ctx.g.getSysType(n.info, tyBool))))
      let
        afterUnroll = breakableCtx.outState[0]
        unrollUntil =
          if isNil(breakableCtx.nearestFinally):
            newIntTypeNode(0, ctx.g.getSysType(n.info, tyInt))
          else:
            breakableCtx.nearestFinally
      result.add(newTree(nkAsgn, ctx.newUnrollUntilAccess(n.info), unrollUntil))
      result.add(newTree(nkAsgn, ctx.newAfterUnrollAccess(n.info), afterUnroll))
      result.add(newTree(nkGotoState, ctx.nearestFinally))

  of nkTryStmt, nkHiddenTryStmt:
    # See explanation above about how this works
    ctx.hasExceptions = true

    var tryBody = toStmtList(n[0])
    var exceptBody = ctx.collectExceptState(n)
    var finallyBody = newTree(nkStmtList, getFinallyNode(ctx, n))
    finallyBody = ctx.transformReturnsInTry(finallyBody)
    finallyBody.add(ctx.newEndFinallyNode(finallyBody.info))

    let tryState = ctx.newState(tryBody)
    let finallyState = ctx.newState(finallyBody)

    let exceptStateId =
      if exceptBody.kind != nkEmpty:
        let s = ctx.newState(exceptBody)
        s[2] = finallyState[0]
        newTree(nkCall, ctx.g.getSysMagic(n.info, "-", mUnaryMinusI).newSymNode, s[0])
      else:
        finallyState[0]
    exceptStateId.typ = ctx.g.getSysType(ctx.fn.info, tyInt)
    tryState[2] = exceptStateId

    result = gotoState(tryState)

    block: # Subdivide the states
      let oldNearestFinally = ctx.nearestFinally
      ctx.nearestFinally = finallyState[0]

      let oldExcHandlingState = ctx.curExcHandlingState
      ctx.curExcHandlingState = exceptStateId

      if ctx.transformReturnsInTry(tryBody) != tryBody:
        internalError(ctx.g.config, "transformReturnsInTry != tryBody")
      if ctx.transformClosureIteratorBody(tryBody, finallyState) != tryBody:
        internalError(ctx.g.config, "transformClosureIteratorBody != tryBody")

      ctx.curExcHandlingState = finallyState[0]
      if exceptBody.kind != nkEmpty:
        ctx.addElseToExcept(exceptBody)
        if ctx.transformReturnsInTry(exceptBody) != exceptBody:
          internalError(ctx.g.config, "transformReturnsInTry != exceptBody")
        if ctx.transformClosureIteratorBody(exceptBody, finallyState) != exceptBody:
          internalError(ctx.g.config, "transformClosureIteratorBody != exceptBody")

      ctx.curExcHandlingState = oldExcHandlingState
      ctx.nearestFinally = oldNearestFinally

      if ctx.transformClosureIteratorBody(finallyBody, outState) != finallyBody:
        internalError(ctx.g.config, "transformClosureIteratorBody != finallyBody")

  of nkGotoState, nkForStmt, nkContinueStmt:
    internalError(ctx.g.config, "closure iter " & $n.kind)

  else:
    for i in 0..<n.len:
      n[i] = ctx.transformClosureIteratorBody(n[i], outState)

proc checkStateAssignment(ctx: var Ctx, n: PNode) =
  assert n.kind == nkGotoState
  if n[0].kind == nkDotExpr: return
  assert n[0].kind == nkIntLit

  if n[0] == ctx.exitState[0]: return
  for state in ctx.states:
    if n[0] == state[0]:
      return
  assert false

proc checkAllStateAssignment(ctx: var Ctx, n: PNode) =
  if n.kind == nkGotoState:
    ctx.checkStateAssignment(n)
  for c in n:
    ctx.checkAllStateAssignment(c)

proc transformStateAssignments(ctx: var Ctx, n: PNode): PNode =
  # This transforms 3 patterns:
  ########################## 1
  # yield e
  # goto STATE
  # ->
  # :state = STATE
  # return e
  ########################## 2
  # goto STATE
  # ->
  # :state = STATE
  # break :stateLoop
  ########################## 3
  # return e
  # ->
  # :state = -1
  # return e
  #
  result = n
  case n.kind
  of nkStmtList, nkStmtListExpr:
    if n.len != 0 and n[0].kind == nkYieldStmt:
      assert(n.len == 2)
      assert(n[1].kind == nkGotoState)

      result = newNodeI(nkStmtList, n.info)
      assert(n[1][0].kind == nkIntLit)
      result.add(ctx.newStateAssgn(n[1][0]))

      var retStmt = newNodeI(nkReturnStmt, n.info)
      if n[0][0].kind != nkEmpty:
        var a = newNodeI(nkAsgn, n[0][0].info)
        var retVal = n[0][0] #liftCapturedVars(n[0], owner, d, c)
        a.add newSymNode(getClosureIterResult(ctx.g, ctx.fn, ctx.idgen))
        a.add retVal
        retStmt.add(a)
      else:
        retStmt.add(ctx.g.emptyNode)

      result.add(retStmt)
    else:
      for i in 0..<n.len:
        n[i] = ctx.transformStateAssignments(n[i])

  of nkSkip:
    discard

  of nkReturnStmt:
    result = newNodeI(nkStmtList, n.info)
    result.add(ctx.newStateAssgn(-1))
    result.add(n)

  of nkGotoState:
    result = newNodeI(nkStmtList, n.info)
    result.add(ctx.newStateAssgn(n[0]))

    let breakState = newNodeI(nkBreakStmt, n.info)
    breakState.add(newSymNode(ctx.stateLoopLabel))
    result.add(breakState)

  else:
    for i in 0..<n.len:
      n[i] = ctx.transformStateAssignments(n[i])

proc skipStmtList(ctx: Ctx; n: PNode): PNode =
  result = n
  while result.kind in {nkStmtList}:
    if result.len == 0: return ctx.g.emptyNode
    result = result[0]

proc newArrayType(g: ModuleGraph; n: int, t: PType; idgen: IdGenerator; owner: PSym): PType =
  result = newType(tyArray, nextTypeId(idgen), owner)

  let rng = newType(tyRange, nextTypeId(idgen), owner)
  rng.n = newTree(nkRange, g.newIntLit(owner.info, 0), g.newIntLit(owner.info, n))
  rng.rawAddSon(t)

  result.rawAddSon(rng)
  result.rawAddSon(t)

proc createExceptionTable(ctx: var Ctx): PNode {.inline.} =
  result = newNodeI(nkBracket, ctx.fn.info)
  result.typ = ctx.g.newArrayType(ctx.states.len, ctx.g.getSysType(ctx.fn.info, tyInt16), ctx.idgen, ctx.fn)

  for state in ctx.states:
    if state[1].kind != nkEmpty:
      result.add(state[1])
    else:
      let elem = newIntNode(nkIntLit, 0)
      elem.typ = ctx.g.getSysType(ctx.fn.info, tyInt16)
      result.add(elem)

proc newCatchBody(ctx: var Ctx, info: TLineInfo): PNode {.inline.} =
  # Generates the code:
  # :state = exceptionTable[:state]
  # if :state == 0: raise
  # :unrollFinally = :state > 0
  # if :state < 0:
  #   :state = -:state
  # :curExc = getCurrentException()

  result = newNodeI(nkStmtList, info)

  let intTyp = ctx.g.getSysType(info, tyInt)
  let boolTyp = ctx.g.getSysType(info, tyBool)

  # :state = exceptionTable[:state]
  block:
    # exceptionTable[:state]
    let getNextState = newTree(nkBracketExpr,
      ctx.createExceptionTable(),
      ctx.newStateAccess())
    getNextState.typ = intTyp

    # :state = exceptionTable[:state]
    result.add(ctx.newStateAssgn(getNextState))

  # if :state == 0: raise
  block:
    let cond = newTree(nkCall,
      ctx.g.getSysMagic(info, "==", mEqI).newSymNode(),
      ctx.newStateAccess(),
      newIntTypeNode(0, intTyp))
    cond.typ = boolTyp

    let raiseStmt = newTree(nkRaiseStmt, ctx.g.emptyNode)
    let ifBranch = newTree(nkElifBranch, cond, raiseStmt)
    let ifStmt = newTree(nkIfStmt, ifBranch)
    result.add(ifStmt)

  # :unrollFinally = :state > 0
  block:
    let cond = newTree(nkCall,
      ctx.g.getSysMagic(info, "<", mLtI).newSymNode,
      newIntTypeNode(0, intTyp),
      ctx.newStateAccess())
    cond.typ = boolTyp

    let asgn = newTree(nkAsgn, ctx.newUnrollFinallyAccess(info), cond)
    result.add(asgn)
    result.add(newTree(nkAsgn, ctx.newUnrollUntilAccess(info), newIntTypeNode(-1, ctx.g.getSysType(info, tyInt))))

  # if :state < 0: :state = -:state
  block:
    let cond = newTree(nkCall,
      ctx.g.getSysMagic(info, "<", mLtI).newSymNode,
      ctx.newStateAccess(),
      newIntTypeNode(0, intTyp))
    cond.typ = boolTyp

    let negateState = newTree(nkCall,
      ctx.g.getSysMagic(info, "-", mUnaryMinusI).newSymNode,
      ctx.newStateAccess())
    negateState.typ = intTyp

    let ifBranch = newTree(nkElifBranch, cond, ctx.newStateAssgn(negateState))
    let ifStmt = newTree(nkIfStmt, ifBranch)
    result.add(ifStmt)

  # :curExc = getCurrentException()
  block:
    result.add(newTree(nkAsgn,
      ctx.newCurExcAccess(),
      ctx.g.callCodegenProc("getCurrentException")))

proc wrapIntoTryExcept(ctx: var Ctx, n: PNode): PNode {.inline.} =
  let setupExc = newTree(nkCall,
    newSymNode(ctx.g.getCompilerProc("closureIterSetupExc")),
    ctx.newCurExcAccess())

  let tryBody = newTree(nkStmtList, setupExc, n)
  let exceptBranch = newTree(nkExceptBranch, ctx.newCatchBody(ctx.fn.info))

  result = newTree(nkTryStmt, tryBody, exceptBranch)

proc wrapIntoStateLoop(ctx: var Ctx, n: PNode): PNode =
  # while true:
  #   block :stateLoop:
  #     gotoState :state
  #     local vars decl (if needed)
  #     body # Might get wrapped in try-except
  let loopBody = newNodeI(nkStmtList, n.info)
  result = newTree(nkWhileStmt, newSymNode(ctx.g.getSysSym(n.info, "true")), loopBody)
  result.info = n.info

  let localVars = newNodeI(nkStmtList, n.info)
  if not ctx.stateVarSym.isNil:
    let varSect = newNodeI(nkVarSection, n.info)
    addVar(varSect, newSymNode(ctx.stateVarSym))
    localVars.add(varSect)

    if not ctx.tempVars.isNil:
      localVars.add(ctx.tempVars)

  let blockStmt = newNodeI(nkBlockStmt, n.info)
  blockStmt.add(newSymNode(ctx.stateLoopLabel))

  let gs = newNodeI(nkGotoState, n.info)
  gs.add(ctx.newStateAccess())
  gs.add(ctx.g.newIntLit(n.info, ctx.states.len - 1))

  var blockBody = newTree(nkStmtList, gs, localVars, n)
  if ctx.hasExceptions:
    blockBody = ctx.wrapIntoTryExcept(blockBody)

  blockStmt.add(blockBody)
  loopBody.add(blockStmt)

proc isEmptyState(ctx: var Ctx, state: PNode): bool =
  if state == ctx.exitState: return false
  skipStmtList(ctx, state[1]).kind == nkGotoState

proc getStateFromId(ctx: var Ctx, stateId: PNode): PNode =
  if stateId == ctx.exitState[0]: return ctx.exitState
  for index, state in ctx.states:
    if state[0] == stateId:
      return state
  assert false

proc deleteEmptyStates(ctx: var Ctx) =
  var
    iValid = 0
    toRemove: seq[PNode]

  # Assign final indices to concrete states
  for i, s in ctx.states:
    if i > 0 and i != ctx.states.len - 1 and ctx.isEmptyState(s):
      toRemove.add(s)
    else:
      s[0].intVal = iValid
      inc iValid

  for empty in toRemove:
    # This is an empty state. Find the linked full state
    var concreteState = empty
    while ctx.isEmptyState(concreteState):
      concreteState = ctx.getStateFromId(ctx.skipStmtList(concreteState[1])[0])

    # Point the id to the concrete state
    empty[0].intVal = concreteState[0].intVal

  # Remove the empty states
  var i = 0
  while i < ctx.states.len:
    if ctx.states[i] in toRemove:
      ctx.states.delete(i)
    else:
      inc i

proc transformClosureIterator*(g: ModuleGraph; idgen: IdGenerator; fn: PSym, n: PNode): PNode =
  var ctx: Ctx
  ctx.g = g
  ctx.fn = fn
  ctx.idgen = idgen

  if getEnvParam(fn).isNil:
    # Lambda lifting was not done yet. Use temporary :state sym, which will
    # be handled specially by lambda lifting. Local temp vars (if needed)
    # should follow the same logic.
    ctx.stateVarSym = newSym(skVar, getIdent(ctx.g.cache, ":state"), nextSymId(idgen), fn, fn.info)
    ctx.stateVarSym.typ = g.createClosureIterStateType(fn, idgen)
  ctx.stateLoopLabel = newSym(skLabel, getIdent(ctx.g.cache, ":stateLoop"), nextSymId(idgen), fn, fn.info)
  var n = n.toStmtList

  discard ctx.newState(n)
  ctx.exitState = newTree(nkState, g.newIntLit(n.info, -1))

  # echo "INPUT --------"
  # echo renderTree(n)
  # echo "----"

  var ns = false
  n = ctx.lowerStmtListExprs(n, ns)

  if n.hasYieldsInExpressions():
    internalError(ctx.g.config, "yield in expr not lowered")

  # Splitting transformation
  discard ctx.transformClosureIteratorBody(n, ctx.exitState)

  for i, s in ctx.states:
    ctx.checkAllStateAssignment(s[1])
    assert s[2].kind in {nkIntLit, nkEmpty, nkCall}

  # Optimize empty states away
  ctx.deleteEmptyStates()

  # Make new body by concatenating the list of states
  result = newNodeI(nkStmtList, n.info)
  for s in ctx.states:
    assert(s.len == 3)
    let body = s[1]
    s.sons.del(1)
    result.add(s)
    result.add(body)

  result = ctx.transformStateAssignments(result)
  result = ctx.wrapIntoStateLoop(result)

  # Remove the exceptions infos from states
  for s in ctx.states:
    s.sons.del(1)

  # echo "TRANSFORM TO STATES: "
  # echo renderTree(result)

  # echo "exception table:"
  # for i, e in ctx.exceptionTable:
  #   echo i, " -> ", e
