#include <stdio.h>
#include "vm.h"

#define SIGN_MASK ((uint64_t)1 << 63)
#define TAGGED_VALUE_MASK ((uint64_t)0x7ffc000000000000)
#define TAG_MASK (((uint32_t)1 << 3) - 1)
#define TAGGED_PRIMITIVE_MASK (TAGGED_VALUE_MASK | ((uint64_t)TAG_MASK << 32))
#define TAG_NONE ((uint8_t)0)
#define TAG_BOOLEAN ((uint8_t)1)
#define TAG_ERROR ((uint8_t)2)
#define TAG_INTEGER ((uint8_t)7)
#define INTEGER_MASK (TAGGED_VALUE_MASK | ((uint64_t)TAG_INTEGER << 32))
#define BOOLEAN_MASK (TAGGED_VALUE_MASK | ((uint64_t)TAG_BOOLEAN << 32))
#define FALSE_MASK BOOLEAN_MASK
#define TRUE_BIT_MASK ((uint64_t)1)
#define TRUE_MASK (BOOLEAN_MASK | TRUE_BIT_MASK)
#define NONE_MASK (TAGGED_VALUE_MASK | ((uint64_t)TAG_NONE << 32))
#define POINTER_MASK (TAGGED_VALUE_MASK | SIGN_MASK)
#define ERROR_MASK = (TAGGED_VALUE_MASK | ((uint64_t)TAG_ERROR << 32);

// Construct value.
#define VALUE_INTEGER(n) (INTEGER_MASK | n)
#define VALUE_BOOLEAN(b) (b ? TRUE_MASK : FALSE_MASK)
#define VALUE_NONE NONE_MASK
#define VALUE_NUMBER(n) ((ValueUnion){ .d = n }.u)
#define VALUE_TRUE TRUE_MASK
#define VALUE_FALSE FALSE_MASK
#define VALUE_RAW(u) u

// Value ops.
#define VALUE_AS_HEAPOBJECT(v) ((HeapObject*)(v & ~POINTER_MASK))
#define VALUE_AS_INTEGER(v) ((int32_t)(v & 0xffffffff))
#define VALUE_AS_NUMBER(v) ((ValueUnion){ .u = v }.d)
#define VALUE_AS_BOOLEAN(v) (v == TRUE_MASK)
#define VALUE_IS_BOOLEAN(v) ((v & (TAGGED_PRIMITIVE_MASK | SIGN_MASK)) == BOOLEAN_MASK)
#define VALUE_IS_POINTER(v) ((v & POINTER_MASK) == POINTER_MASK)
#define VALUE_ASSUME_NOT_BOOL_TO_BOOL(v) VALUE_IS_NONE(v)
#define VALUE_IS_NONE(v) (v == NONE_MASK)
#define VALUE_IS_PANIC(v) (ERROR_MASK | (uint32_t)(0xff << 8) | UINT8_MAX)
#define VALUE_IS_NUMBER(v) ((v & TAGGED_VALUE_MASK) != TAGGED_VALUE_MASK)
#define VALUE_BOTH_NUMBERS(v1, v2) (VALUE_IS_NUMBER(v1) && VALUE_IS_NUMBER(v2))
#define VALUE_GET_TAG(v) (((uint32_t)(v >> 32)) & TAG_MASK)

static inline void release(VM* vm, Value val) {
    // if (cy.TraceEnabled) {
    //     vm.trace.numReleaseAttempts += 1;
    // }
    if (VALUE_IS_POINTER(val)) {
        HeapObject* obj = VALUE_AS_HEAPOBJECT(val);
        // if (builtin.mode == .Debug) {
        //     if (obj.retainedCommon.structId == cy.NullId) {
        //         log.debug("object already freed. {*}", .{obj});
        //         cy.debug.dumpObjectTrace(vm, obj) catch stdx.fatal();
        //         stdx.fatal();
        //     }
        // }
        obj->retainedCommon.rc -= 1;
        // if (builtin.mode == .Debug) {
        //     if (cy.verbose) {
        //         log.debug("release {} {}", .{val.getUserTag(), obj.retainedCommon.rc});
        //     }
        // }
#if TRACK_GLOBAL_RC
        vm->refCounts -= 1;
#endif
        // if (cy.TraceEnabled) {
        //     vm.trace.numReleases += 1;
        // }
        if (obj->retainedCommon.rc == 0) {
            zFreeObject(vm, obj);
        }
    }
}

static inline void retain(VM* vm, Value val) {
    // if (cy.TraceEnabled) {
    //     self.trace.numRetainAttempts += 1;
    // }
    if (VALUE_IS_POINTER(val)) {
        HeapObject* obj = VALUE_AS_HEAPOBJECT(val);
        obj->retainedCommon.rc += 1;
        // if (builtin.mode == .Debug) {
        //     if (cy.verbose) {
        //         log.debug("retain {} {}", .{obj.getUserTag(), obj.retainedCommon.rc});
        //     }
        // }
#if TRACK_GLOBAL_RC
        vm->refCounts += 1;
#endif
        // if (cy.TraceEnabled) {
        //     self.trace.numRetains += 1;
        // }
    }
}

static inline double toF64(Value val) {
    if (VALUE_IS_NUMBER(val)) {
        return VALUE_AS_NUMBER(val);
    } else {
        return zOtherToF64(val);
    }
}

static inline TypeId getPrimitiveTypeId(Value val) {
    if (VALUE_IS_NUMBER(val)) {
        return TYPE_NUMBER;
    } else {
        return VALUE_GET_TAG(val);
    }
}

static inline TypeId getTypeId(Value val) {
    if (VALUE_IS_POINTER(val)) {
        return VALUE_AS_HEAPOBJECT(val)->retainedCommon.typeId;
    } else {
        return getPrimitiveTypeId(val);
    }
}

ResultCode execBytecode(VM* vm) {
    #define READ_I16(offset) ((int16_t)(pc[offset] | ((uint16_t)pc[offset + 1] << 8)))
    #define READ_U16(offset) (pc[offset] | ((uint16_t)pc[offset + 1] << 8))
    #define READ_U48(offset) ((uint64_t)pc[offset] | ((uint64_t)pc[offset+1] << 8) | ((uint64_t)pc[offset+2] << 16) | ((uint64_t)pc[offset+3] << 24) | ((uint64_t)pc[offset+4] << 32) | ((uint64_t)pc[offset+5] << 40))
#if DEBUG    
    #define PRE_NEXT() \
        if (verbose) { \
            zDumpEvalOp(vm, pc); \
        } \
        //vm.debugPc = pcOffset(vm, pc);
#else
    #define PRE_NEXT()
#endif
#if CGOTO
    #define JENTRY(op) &&Code_##op
    static void* jumpTable[] = {
        JENTRY(ConstOp),
        JENTRY(ConstI8),
        JENTRY(ConstI8Int),
        JENTRY(Add),
        JENTRY(Sub),
        JENTRY(True),
        JENTRY(False),
        JENTRY(None),
        JENTRY(Not),
        JENTRY(Copy),
        JENTRY(CopyReleaseDst),
        JENTRY(SetIndex),
        JENTRY(SetIndexRelease),
        JENTRY(CopyRetainSrc),
        JENTRY(Index),
        JENTRY(ReverseIndex),
        JENTRY(List),
        JENTRY(Map),
        JENTRY(MapEmpty),
        JENTRY(Slice),
        JENTRY(JumpNotCond),
        JENTRY(JumpCond),
        JENTRY(Jump),
        JENTRY(Release),
        JENTRY(ReleaseN),
        JENTRY(CallObjSym),
        JENTRY(CallObjNativeFuncIC),
        JENTRY(CallObjFuncIC),
        JENTRY(CallSym),
        JENTRY(CallFuncIC),
        JENTRY(CallNativeFuncIC),
        JENTRY(Ret1),
        JENTRY(Ret0),
        JENTRY(Call0),
        JENTRY(Call1),
        JENTRY(Field),
        JENTRY(FieldIC),
        JENTRY(FieldRetain),
        JENTRY(FieldRetainIC),
        JENTRY(FieldRelease),
        JENTRY(Lambda),
        JENTRY(Closure),
        JENTRY(Compare),
        JENTRY(Less),
        JENTRY(Greater),
        JENTRY(LessEqual),
        JENTRY(GreaterEqual),
        JENTRY(Mul),
        JENTRY(Div),
        JENTRY(Pow),
        JENTRY(Mod),
        JENTRY(CompareNot),
        JENTRY(StringTemplate),
        JENTRY(Neg),
        JENTRY(SetInitN),
        JENTRY(ObjectSmall),
        JENTRY(Object),
        JENTRY(SetField),
        JENTRY(SetFieldRelease),
        JENTRY(SetFieldReleaseIC),
        JENTRY(Coinit),
        JENTRY(Coyield),
        JENTRY(Coresume),
        JENTRY(Coreturn),
        JENTRY(Retain),
        JENTRY(CopyRetainRelease),
        JENTRY(Box),
        JENTRY(SetBoxValue),
        JENTRY(SetBoxValueRelease),
        JENTRY(BoxValue),
        JENTRY(BoxValueRetain),
        JENTRY(Tag),
        JENTRY(TagLiteral),
        JENTRY(TryValue),
        JENTRY(BitwiseAnd),
        JENTRY(BitwiseOr),
        JENTRY(BitwiseXor),
        JENTRY(BitwiseNot),
        JENTRY(BitwiseLeftShift),
        JENTRY(BitwiseRightShift),
        JENTRY(JumpNotNone),
        JENTRY(AddInt),
        JENTRY(SubInt),
        JENTRY(LessInt),
        JENTRY(ForRangeInit),
        JENTRY(ForRange),
        JENTRY(ForRangeReverse),
        JENTRY(Match),
        JENTRY(StaticFunc),
        JENTRY(StaticVar),
        JENTRY(SetStaticVar),
        JENTRY(SetStaticFunc),
        JENTRY(Sym),
        JENTRY(End),
    };
    #define CASE(op) Code_##op
    #define NEXT() PRE_NEXT(); goto *jumpTable[*pc]
#else
    // case name matches enum.
    #define CASE(op) case Code##op
    #define NEXT() PRE_NEXT(); goto beginSwitch
#endif

    register Inst* pc; 
    register Value* stack;

    pc = vm->curPc;
    stack = vm->curStack;

#if CGOTO
    // Goto first instruction.
    NEXT();
#else 
beginSwitch:
    switch ((OpCode)*pc) {
#endif
    CASE(ConstOp):
        stack[pc[2]] = VALUE_RAW(vm->constPtr[pc[1]]);
        pc += 3;
        NEXT();
    CASE(ConstI8):
        stack[pc[2]] = VALUE_NUMBER((double)(int8_t)pc[1]);
        pc += 3;
        NEXT();
    CASE(ConstI8Int):
        stack[pc[2]] = VALUE_INTEGER((int32_t)pc[1]);
        pc += 3;
        NEXT();
    CASE(Add): {
        Value left = stack[pc[1]];
        Value right = stack[pc[2]];
        if (VALUE_BOTH_NUMBERS(left, right)) {
            stack[pc[3]] = VALUE_NUMBER(VALUE_AS_NUMBER(left) + VALUE_AS_NUMBER(right));
        } else {
            ValueResult res = zEvalAddFallback(vm, left, right);
            if (res.code != RES_CODE_SUCCESS) {
                return res.code;
            }
            stack[pc[3]] = res.val;
        }
        pc += 4;
        NEXT();
    }
    CASE(Sub): {
        Value left = stack[pc[1]];
        Value right = stack[pc[2]];
        if (VALUE_BOTH_NUMBERS(left, right)) {
            stack[pc[3]] = VALUE_NUMBER(VALUE_AS_NUMBER(left) - VALUE_AS_NUMBER(right));
        } else {
            ValueResult res = zEvalSubFallback(vm, left, right);
            if (res.code != RES_CODE_SUCCESS) {
                return res.code;
            }
            stack[pc[3]] = res.val;
        }
        pc += 4;
        NEXT();
    }
    CASE(True):
        stack[pc[1]] = VALUE_TRUE;
        pc += 2;
        NEXT();
    CASE(False):
        stack[pc[1]] = VALUE_FALSE;
        pc += 2;
        NEXT();
    CASE(None):
        stack[pc[1]] = VALUE_NONE;
        pc += 2;
        NEXT();
    CASE(Not):
        printf("Unsupported %s\n", zOpCodeName(*pc));
        zFatal();
    CASE(Copy):
        stack[pc[2]] = stack[pc[1]];
        pc += 3;
        NEXT();
    CASE(CopyReleaseDst): {
        uint8_t dst = pc[2];
        release(vm, stack[dst]);
        stack[dst] = stack[pc[1]];
        pc += 3;
        NEXT();
    }
    CASE(SetIndex):
    CASE(SetIndexRelease):
        printf("Unsupported %s\n", zOpCodeName(*pc));
        zFatal();
    CASE(CopyRetainSrc): {
        Value val = stack[pc[1]];
        retain(vm, val);
        stack[pc[2]] = val;
        pc += 3;
        NEXT();
    }
    CASE(Index):
    CASE(ReverseIndex):
        printf("Unsupported %s\n", zOpCodeName(*pc));
        zFatal();
    CASE(List): {
        uint8_t startLocal = pc[1];
        uint8_t numElems = pc[2];
        ValueResult res = zAllocList(vm, stack + startLocal, numElems);
        if (res.code != RES_CODE_SUCCESS) {
            return res.code;
        }
        stack[pc[3]] = res.val;
        pc += 4;
        NEXT();
    }
    CASE(Map):
    CASE(MapEmpty):
    CASE(Slice):
        printf("Unsupported %s\n", zOpCodeName(*pc));
        zFatal();
    CASE(JumpNotCond): {
        uint16_t jump = READ_U16(1);
        Value cond = stack[pc[3]];
        bool condVal = VALUE_IS_BOOLEAN(cond) ? VALUE_AS_BOOLEAN(cond) : VALUE_ASSUME_NOT_BOOL_TO_BOOL(cond);
        if (!condVal) {
            pc += jump;
        } else {
            pc += 4;
        }
        NEXT();
    }
    CASE(JumpCond):
        printf("Unsupported %s\n", zOpCodeName(*pc));
        zFatal();
    CASE(Jump):
        pc += READ_I16(1);
        NEXT();
    CASE(Release):
        release(vm, stack[pc[1]]);
        pc += 2;
        NEXT();
    CASE(ReleaseN):
        printf("Unsupported %s\n", zOpCodeName(*pc));
        zFatal();
    CASE(CallObjSym): {
        uint8_t startLocal = pc[1];
        uint8_t numArgs = pc[2];
        uint8_t numRet = pc[3];
        uint8_t symId = pc[4];

        Value recv = stack[startLocal + numArgs + 4 - 1];
        TypeId typeId = getTypeId(recv);

        CallObjSymResult res = zCallObjSym(vm, pc, stack, recv, typeId, symId, startLocal, numArgs, numRet);
        if (res.code != RES_CODE_SUCCESS) {
            return res.code;
        }
        pc = res.pc;
        stack = res.stack;
        NEXT();
    }
    CASE(CallObjNativeFuncIC): {
        uint8_t startLocal = pc[1];
        uint8_t numArgs = pc[2];
        Value recv = stack[startLocal + numArgs + 4 - 1];
        TypeId typeId = getTypeId(recv);

        TypeId cachedTypeId = READ_U16(12);
        if (typeId == cachedTypeId) {
            // const newFramePtr = framePtr + startLocal;
            vm->curStack = stack;
            MethodPtr fn = (MethodPtr)READ_U48(6);
            Value res = fn(vm, recv, stack + startLocal + 4, numArgs);
            // if (VALUE_IS_PANIC(res)) {
            //     return error.Panic;
            // }
            uint8_t numRet = pc[3];
            if (numRet == 1) {
                stack[startLocal] = res;
            } else {
                switch (numRet) {
                    case 0: 
                        // Nop.
                        break;
                    case 1:
                        // Not possible.
                        zFatal();
                    default:
                        zFatal();
                }
            }
            pc += 14;
            // In the future, we might allow native functions to change the pc and framePtr.
            // pc = vm.pc;
            // framePtr = vm.framePtr;
            NEXT();
        }

        // Deoptimize.
        pc[0] = CodeCallObjSym;
        NEXT();
    }
    CASE(CallObjFuncIC):
        printf("Unsupported %s\n", zOpCodeName(*pc));
        zFatal();
    CASE(CallSym): {
        uint8_t startLocal = pc[1];
        uint8_t numArgs = pc[2];
        uint8_t numRet = pc[3];
        uint8_t symId = pc[4];
        CallSymResult res = zCallSym(vm, pc, stack, symId, startLocal, numArgs, numRet);
        pc = res.pc;
        stack = res.stack;
        NEXT();
    }
    CASE(CallFuncIC): {
        uint8_t startLocal = pc[1];
        uint8_t numLocals = pc[4];
        if (stack + startLocal + numLocals >= vm->stackEndPtr) {
        //     return error.StackOverflow;
            zFatal();
        }

        Value retFramePtr = (uintptr_t)stack;
        stack += startLocal;
        *(uint8_t*)(stack + 1) = pc[3];
        *((uint8_t*)(stack + 1) + 1) = 0;
        stack[2] = (uintptr_t)(pc + 11);
        stack[3] = retFramePtr;
        pc = (Inst*)READ_U48(5);
        NEXT();
    }
    CASE(CallNativeFuncIC): {
        uint8_t startLocal = pc[1];
        uint8_t numArgs = pc[2];

        Value* newStack = stack + startLocal;
        vm->curStack = newStack;
        FuncPtr fn = (FuncPtr)READ_U48(5);
        Value res = fn(vm, newStack + 4, numArgs);
        // if (res.isPanic()) {
        //     return error.Panic;
        // }
        uint8_t numRet = pc[3];
        if (numRet == 1) {
            newStack[0] = res;
        } else {
            switch (numRet) {
                case 0:
                    // Nop.
                    break;
                case 1:
                    zFatal();
                default:
                    zFatal();
            }
        }
        pc += 11;
        NEXT();
    }
    CASE(Ret1): {
        uint8_t reqNumArgs = *(uint8_t*)(stack + 1);
        bool retFlag = ((*((uint8_t*)(stack + 1) + 1)) & 0x1 > 0);
        if (reqNumArgs == 1) {
            pc = (Inst*)stack[2];
            stack = (Value*)stack[3];
            if (!retFlag) {
                NEXT();
            } else {
                return RES_CODE_SUCCESS;
            }
        } else {
            switch (reqNumArgs) {
                case 0: {
                    release(vm, stack[0]);
                    break;
                }
                case 1:
                    zFatal();
                default:
                    zFatal();
            }
            pc = (Inst*)stack[2];
            stack = (Value*)stack[3];
            if (!retFlag) {
                NEXT();
            } else {
                return RES_CODE_SUCCESS;
            }
        }
    }
    CASE(Ret0):
    CASE(Call0):
    CASE(Call1):
    CASE(Field):
    CASE(FieldIC):
    CASE(FieldRetain):
    CASE(FieldRetainIC):
    CASE(FieldRelease):
    CASE(Lambda):
    CASE(Closure):
    CASE(Compare):
    CASE(Less):
    CASE(Greater):
    CASE(LessEqual):
    CASE(GreaterEqual):
    CASE(Mul):
    CASE(Div):
    CASE(Pow):
    CASE(Mod):
    CASE(CompareNot):
    CASE(StringTemplate):
    CASE(Neg):
        printf("Unsupported %s\n", zOpCodeName(*pc));
        zFatal();
    CASE(SetInitN): {
        uint8_t numLocals = pc[1];
        uint8_t i;
        for (i = 2; i < 2 + numLocals; i += 1) {
            stack[i] = VALUE_NONE;
        }
        pc += 2 + numLocals;
        NEXT();
    }
    CASE(ObjectSmall):
    CASE(Object):
    CASE(SetField):
    CASE(SetFieldRelease):
    CASE(SetFieldReleaseIC):
    CASE(Coinit):
    CASE(Coyield):
    CASE(Coresume):
    CASE(Coreturn):
    CASE(Retain):
    CASE(CopyRetainRelease):
    CASE(Box):
    CASE(SetBoxValue):
    CASE(SetBoxValueRelease):
    CASE(BoxValue):
    CASE(BoxValueRetain):
    CASE(Tag):
    CASE(TagLiteral):
    CASE(TryValue):
    CASE(BitwiseAnd):
    CASE(BitwiseOr):
    CASE(BitwiseXor):
    CASE(BitwiseNot):
    CASE(BitwiseLeftShift):
    CASE(BitwiseRightShift):
        printf("Unsupported %s\n", zOpCodeName(*pc));
        zFatal();
    CASE(JumpNotNone): {
        int16_t offset = READ_I16(1);
        if (!VALUE_IS_NONE(stack[pc[3]])) {
            pc += offset;
            NEXT();
        } else {
            pc += 4;
            NEXT();
        }
    }
    CASE(AddInt): {
        Value left = stack[pc[1]];
        Value right = stack[pc[2]];
        stack[pc[3]] = VALUE_INTEGER(VALUE_AS_INTEGER(left) + VALUE_AS_INTEGER(right));
        pc += 4;
        NEXT();
    }
    CASE(SubInt): {
        Value left = stack[pc[1]];
        Value right = stack[pc[2]];
        stack[pc[3]] = VALUE_INTEGER(VALUE_AS_INTEGER(left) - VALUE_AS_INTEGER(right));
        pc += 4;
        NEXT();
    }
    CASE(LessInt): {
        Value left = stack[pc[1]];
        Value right = stack[pc[2]];
        stack[pc[3]] = VALUE_BOOLEAN(VALUE_AS_INTEGER(left) < VALUE_AS_INTEGER(right));
        pc += 4;
        NEXT();
    }
    CASE(ForRangeInit): {
        double start = toF64(stack[pc[1]]);
        double end = toF64(stack[pc[2]]);
        stack[pc[2]] = VALUE_NUMBER(end);
        double step = toF64(stack[pc[3]]);
        if (step < 0) {
            step = -step;
        }
        stack[pc[3]] = VALUE_NUMBER(step);
        if (start == end) {
            pc += READ_U16(6) + 7;
            NEXT();
        } else {
            stack[pc[4]] = VALUE_NUMBER(start);
            stack[pc[5]] = VALUE_NUMBER(start);
            uint16_t offset = READ_U16(6);
            if (start < end) {
                pc[offset] = CodeForRange;
            } else {
                pc[offset] = CodeForRangeReverse;
            }
            pc += 8;
            NEXT();
        }
    }
    CASE(ForRange): {
        double counter = VALUE_AS_NUMBER(stack[pc[1]]) + VALUE_AS_NUMBER(stack[pc[2]]);
        if (counter < VALUE_AS_NUMBER(stack[pc[3]])) {
            stack[pc[1]] = VALUE_NUMBER(counter);
            stack[pc[4]] = VALUE_NUMBER(counter);
            pc -= READ_U16(5);
        } else {
            pc += 7;
        }
        NEXT();
    }
    CASE(ForRangeReverse):
    CASE(Match):
    CASE(StaticFunc):
    CASE(StaticVar):
    CASE(SetStaticVar):
    CASE(SetStaticFunc):
    CASE(Sym):
        printf("Unsupported %s\n", zOpCodeName(*pc));
        zFatal();
    CASE(End):
        zEnd(vm, pc);
        return RES_CODE_SUCCESS;

#if CGOTO
#else
    }
#endif
}