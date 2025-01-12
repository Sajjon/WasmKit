import WasmParser

/// A WebAssembly guest function or host function.
///
/// > Note:
/// <https://webassembly.github.io/spec/core/exec/runtime.html#function-instances>
public struct Function: Equatable {
    internal let handle: InternalFunction
    let allocator: StoreAllocator

    /// The signature type of the function.
    public var type: FunctionType {
        allocator.funcTypeInterner.resolve(handle.type)
    }

    /// Invokes a function of the given address with the given parameters.
    ///
    /// - Parameters:
    ///   - arguments: The arguments to pass to the function.
    ///   - runtime: The runtime to use for the function invocation.
    /// - Throws: A trap if the function invocation fails.
    /// - Returns: The results of the function invocation.
    public func invoke(_ arguments: [Value] = [], runtime: Runtime) throws -> [Value] {
        assert(allocator === runtime.store.allocator, "Function is not from the same store as the runtime")
        return try handle.invoke(arguments, runtime: runtime)
    }
}

@available(*, deprecated, renamed: "Function", message: "Use Function instead")
public typealias FunctionInstance = Function

struct InternalFunction: Equatable, Hashable {
    private let _storage: Int

    var bitPattern: Int { _storage }

    init(bitPattern: Int) {
        _storage = bitPattern
    }

    var isWasm: Bool {
        _storage & 0b1 == 0
    }

    var type: InternedFuncType {
        if isWasm {
            return wasm.type
        } else {
            return host.type
        }
    }

    static func wasm(_ handle: EntityHandle<WasmFunctionEntity>) -> InternalFunction {
        assert(MemoryLayout<WasmFunctionEntity>.alignment >= 2)
        return InternalFunction(bitPattern: handle.bitPattern | 0b0)
    }

    static func host(_ handle: EntityHandle<HostFunctionEntity>) -> InternalFunction {
        assert(MemoryLayout<HostFunctionEntity>.alignment >= 2)
        return InternalFunction(bitPattern: handle.bitPattern | 0b1)
    }

    var wasm: EntityHandle<WasmFunctionEntity> {
        EntityHandle(unsafe: UnsafeMutablePointer(bitPattern: bitPattern & ~0b0)!)
    }
    var host: EntityHandle<HostFunctionEntity> {
        EntityHandle(unsafe: UnsafeMutablePointer(bitPattern: bitPattern & ~0b1)!)
    }
}

extension InternalFunction: ValidatableEntity {
    static func createOutOfBoundsError(index: Int, count: Int) -> any Error {
        Trap.invalidFunctionIndex(index)
    }
}

extension InternalFunction {
    func invoke(_ arguments: [Value], runtime: Runtime) throws -> [Value] {
        if isWasm {
            let entity = wasm
            let resolvedType = runtime.resolveType(entity.type)
            try check(functionType: resolvedType, parameters: arguments)
            return try executeWasm(
                runtime: runtime,
                function: self,
                type: resolvedType,
                arguments: arguments,
                callerInstance: entity.instance
            )
        } else {
            let entity = host
            let resolvedType = runtime.resolveType(entity.type)
            try check(functionType: resolvedType, parameters: arguments)
            let caller = Caller(instanceHandle: nil, runtime: runtime)
            let results = try entity.implementation(caller, arguments)
            try check(functionType: resolvedType, results: results)
            return results
        }
    }

    private func check(functionType: FunctionType, parameters: [Value]) throws {
        let parameterTypes = parameters.map { $0.type }

        guard parameterTypes == functionType.parameters else {
            throw Trap._raw("parameters types don't match, expected \(functionType.parameters), got \(parameterTypes)")
        }
    }

    private func check(functionType: FunctionType, results: [Value]) throws {
        let resultTypes = results.map { $0.type }

        guard resultTypes == functionType.results else {
            throw Trap._raw("result types don't match, expected \(functionType.results), got \(resultTypes)")
        }
    }

    @inline(never)
    func ensureCompiled(executionState: inout ExecutionState) throws {
        try ensureCompiled(runtime: executionState.runtime)
    }
    func ensureCompiled(runtime: RuntimeRef) throws {
        let entity = self.wasm
        switch entity.code {
        case .uncompiled(let code):
            try entity.withValue {
                let iseq = try $0.compile(runtime: runtime, code: code)
                $0.code = .compiled(iseq)
            }
        case .compiled: break
        }
    }

    func assumeCompiled() -> (
        InstructionSequence,
        locals: Int,
        instance: InternalInstance
    ) {
        let entity = self.wasm
        guard case let .compiled(iseq) = entity.code else {
            preconditionFailure()
        }
        return (iseq, entity.numberOfNonParameterLocals, entity.instance)
    }
}


struct WasmFunctionEntity {
    let type: InternedFuncType
    let instance: InternalInstance
    let numberOfNonParameterLocals: Int
    var code: CodeBody

    init(type: InternedFuncType, code: InternalUncompiledCode, instance: InternalInstance) {
        self.type = type
        self.instance = instance
        self.code = .uncompiled(code)
        self.numberOfNonParameterLocals = code.locals.count
    }

    mutating func ensureCompiled(executionState: inout ExecutionState) throws -> InstructionSequence {
        try ensureCompiled(runtime: executionState.runtime)
    }

    mutating func ensureCompiled(runtime: RuntimeRef) throws -> InstructionSequence {
        switch code {
        case .uncompiled(let code):
            return try compile(runtime: runtime, code: code)
        case .compiled(let iseq):
            return iseq
        }
    }

    @inline(never)
    mutating func compile(runtime: RuntimeRef, code: InternalUncompiledCode) throws -> InstructionSequence {
        let type = self.type
        var translator = InstructionTranslator(
            allocator: runtime.value.store.allocator.iseqAllocator,
            funcTypeInterner: runtime.value.funcTypeInterner,
            module: instance,
            type: runtime.value.resolveType(type),
            locals: code.locals
        )

        try WasmParser.parseExpression(
            bytes: Array(code.expression),
            features: instance.features, hasDataCount: instance.hasDataCount,
            visitor: &translator
        )
        let iseq = try translator.finalize()
        self.code = .compiled(iseq)
        return iseq
    }
}

typealias InternalUncompiledCode = EntityHandle<Code>

enum CodeBody {
    case uncompiled(InternalUncompiledCode)
    case compiled(InstructionSequence)
}

extension Reference {
    static func function(from value: InternalFunction) -> Reference {
        // TODO: Consider having internal reference representation instead
        //       of public one in WasmTypes
        return .function(value.bitPattern)
    }
}
