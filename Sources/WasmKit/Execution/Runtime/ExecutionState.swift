/// An execution state of an invocation of exported function.
///
/// Each new invocation through exported function has a separate ``ExecutionState``
/// even though the invocation happens during another invocation.
struct ExecutionState {
    var stack = Stack()
    /// Index of an instruction to be executed in the current function.
    var programCounter = 0

    var isStackEmpty: Bool {
        stack.isEmpty
    }
}

extension ExecutionState: CustomStringConvertible {
    var description: String {
        var result = "======== PC=\(programCounter) =========\n"
        result += "\n\(stack.debugDescription)"

        return result
    }
}

extension ExecutionState {
    mutating func execute(_ instruction: Instruction, runtime: Runtime) throws {
        try doExecute(instruction, runtime: runtime)
    }

    mutating func branch(labelIndex: Int) throws {
        let label = try stack.getLabel(index: Int(labelIndex))
        let values = stack.popValues(count: label.arity)

        stack.unwindLabels(upto: labelIndex)

        stack.push(values: values)
        programCounter = label.continuation
    }

    /// > Note:
    /// <https://webassembly.github.io/spec/core/exec/instructions.html#entering-xref-syntax-instructions-syntax-instr-mathit-instr-ast-with-label-l>
    mutating func enter(_ expression: Expression, continuation: Int, arity: Int) {
        let exit = programCounter + 1
        let label = stack.pushLabel(
            arity: arity,
            expression: expression,
            continuation: continuation,
            exit: exit
        )
        programCounter = label.expression.instructions.startIndex
    }

    /// > Note:
    /// <https://webassembly.github.io/spec/core/exec/instructions.html#exiting-xref-syntax-instructions-syntax-instr-mathit-instr-ast-with-label-l>
    mutating func exit(label: Label) throws {
        stack.exit(label: label)
        programCounter = label.exit
    }

    /// > Note:
    /// <https://webassembly.github.io/spec/core/exec/instructions.html#invocation-of-function-address>
    mutating func invoke(functionAddress address: FunctionAddress, runtime: Runtime) throws {
        // runtime.interceptor?.onEnterFunction(address, store: runtime.store)

        switch try runtime.store.function(at: address) {
        case let .host(function):
            let parameters = stack.popValues(count: function.type.parameters.count)
            let moduleInstance = runtime.store.module(address: stack.currentFrame.module)
            let caller = Caller(runtime: runtime, instance: moduleInstance)
            stack.push(values: try function.implementation(caller, Array(parameters)))

            programCounter += 1

        case let .wasm(function, body: body):
            let expression = body

            let arity = function.type.results.count
            try stack.pushFrame(
                arity: arity,
                module: function.module,
                argc: function.type.parameters.count,
                defaultLocals: function.code.defaultLocals,
                address: address
            )

            self.enter(
                expression, continuation: programCounter + 1,
                arity: arity
            )
        }
    }

    mutating func step(runtime: Runtime) throws {
        if let label = stack.currentLabel, stack.numberOfLabelsInCurrentFrame() > 0 {
            if programCounter < label.expression.instructions.count {
                // Regular path
                try execute(stack.currentLabel.expression.instructions[programCounter], runtime: runtime)
            } else {
                // When reached at "end" of "block" or "loop"
                try self.exit(label: label)
            }
        } else {
            // When reached at "end" of function
            if let address = stack.currentFrame.address {
                runtime.interceptor?.onExitFunction(address, store: runtime.store)
            }
            let values = stack.popValues(count: stack.currentFrame.arity)
            try stack.popFrame()
            stack.push(values: values)
        }
    }

    mutating func run(runtime: Runtime) throws {
        while stack.currentFrame != nil {
            try step(runtime: runtime)
        }
    }

    func currentModule(store: Store) -> ModuleInstance {
        store.module(address: stack.currentFrame.module)
    }
}
// This file is generated by Utilities/generate_inst_dispatch.swift
// swiftlint:disable all
import Foundation

extension ExecutionState {
    mutating func doExecute(_ instruction: Instruction, runtime: Runtime) throws {
        switch instruction {
        case .unreachable:
            try self.unreachable(runtime: runtime)
            return
        case .nop:
            try self.nop(runtime: runtime)
            return
        case .block(let expression, let type):
            try self.block(runtime: runtime, expression: expression, type: type)
            return
        case .loop(let expression, let type):
            try self.loop(runtime: runtime, expression: expression, type: type)
            return
        case .`if`(let thenExpr, let elseExpr, let type):
            try self.`if`(runtime: runtime, thenExpr: thenExpr, elseExpr: elseExpr, type: type)
            return
        case .br(let labelIndex):
            try self.br(runtime: runtime, labelIndex: labelIndex)
            return
        case .brIf(let labelIndex):
            try self.brIf(runtime: runtime, labelIndex: labelIndex)
            return
        case .brTable(let labelIndices, let defaultIndex):
            try self.brTable(runtime: runtime, labelIndices: labelIndices, defaultIndex: defaultIndex)
            return
        case .`return`:
            try self.`return`(runtime: runtime)
            return
        case .call(let functionIndex):
            try self.call(runtime: runtime, functionIndex: functionIndex)
            return
        case .callIndirect(let tableIndex, let typeIndex):
            try self.callIndirect(runtime: runtime, tableIndex: tableIndex, typeIndex: typeIndex)
            return
        case .memoryLoad(let memarg, let bitWidth, let type, let isSigned):
            try self.memoryLoad(runtime: runtime, memarg: memarg, bitWidth: bitWidth, type: type, isSigned: isSigned)
        case .memoryStore(let memarg, let bitWidth, let type):
            try self.memoryStore(runtime: runtime, memarg: memarg, bitWidth: bitWidth, type: type)
        case .memorySize:
            try self.memorySize(runtime: runtime)
        case .memoryGrow:
            try self.memoryGrow(runtime: runtime)
        case .memoryInit(let dataIndex):
            try self.memoryInit(runtime: runtime, dataIndex: dataIndex)
        case .memoryDataDrop(let dataIndex):
            try self.memoryDataDrop(runtime: runtime, dataIndex: dataIndex)
        case .memoryCopy:
            try self.memoryCopy(runtime: runtime)
        case .memoryFill:
            try self.memoryFill(runtime: runtime)
        case .numericConst(let value):
            try self.numericConst(runtime: runtime, value: value)
        case .numericIntUnary(let intUnary):
            try self.numericIntUnary(runtime: runtime, intUnary: intUnary)
        case .numericFloatUnary(let floatUnary):
            try self.numericFloatUnary(runtime: runtime, floatUnary: floatUnary)
        case .numericBinary(let binary):
            try self.numericBinary(runtime: runtime, binary: binary)
        case .numericIntBinary(let intBinary):
            try self.numericIntBinary(runtime: runtime, intBinary: intBinary)
        case .numericFloatBinary(let floatBinary):
            try self.numericFloatBinary(runtime: runtime, floatBinary: floatBinary)
        case .numericConversion(let conversion):
            try self.numericConversion(runtime: runtime, conversion: conversion)
        case .drop:
            try self.drop(runtime: runtime)
        case .select:
            try self.select(runtime: runtime)
        case .typedSelect(let types):
            try self.typedSelect(runtime: runtime, types: types)
        case .refNull(let referenceType):
            try self.refNull(runtime: runtime, referenceType: referenceType)
        case .refIsNull:
            try self.refIsNull(runtime: runtime)
        case .refFunc(let functionIndex):
            try self.refFunc(runtime: runtime, functionIndex: functionIndex)
        case .tableGet(let tableIndex):
            try self.tableGet(runtime: runtime, tableIndex: tableIndex)
        case .tableSet(let tableIndex):
            try self.tableSet(runtime: runtime, tableIndex: tableIndex)
        case .tableSize(let tableIndex):
            try self.tableSize(runtime: runtime, tableIndex: tableIndex)
        case .tableGrow(let tableIndex):
            try self.tableGrow(runtime: runtime, tableIndex: tableIndex)
        case .tableFill(let tableIndex):
            try self.tableFill(runtime: runtime, tableIndex: tableIndex)
        case .tableCopy(let dest, let src):
            try self.tableCopy(runtime: runtime, dest: dest, src: src)
        case .tableInit(let tableIndex, let elementIndex):
            try self.tableInit(runtime: runtime, tableIndex: tableIndex, elementIndex: elementIndex)
        case .tableElementDrop(let elementIndex):
            try self.tableElementDrop(runtime: runtime, elementIndex: elementIndex)
        case .localGet(let index):
            try self.localGet(runtime: runtime, index: index)
        case .localSet(let index):
            try self.localSet(runtime: runtime, index: index)
        case .localTee(let index):
            try self.localTee(runtime: runtime, index: index)
        case .globalGet(let index):
            try self.globalGet(runtime: runtime, index: index)
        case .globalSet(let index):
            try self.globalSet(runtime: runtime, index: index)
        case .pseudo(let pseudoInstruction):
            try self.pseudo(runtime: runtime, pseudoInstruction: pseudoInstruction)
        }
        programCounter += 1
    }
}

// This file is generated by Utilities/generate_inst_dispatch.swift
// swiftlint:disable all
import Foundation

extension ExecutionState {
    mutating func pseudo(runtime: Runtime, pseudoInstruction: PseudoInstruction) throws {
        fatalError("Unimplemented instruction: pseudo")
    }
}
