import WasmParser

/// A simple bump allocator for a single type.
class BumpAllocator<T> {
    private var pages: [UnsafeMutableBufferPointer<T>] = []
    private var currentPage: UnsafeMutableBufferPointer<T>
    private var currentOffset: Int = 0
    private let currentPageSize: Int

    /// Creates a new bump allocator with the given initial capacity.
    init(initialCapacity: Int) {
        currentPageSize = initialCapacity
        currentPage = .allocate(capacity: currentPageSize)
    }

    deinit {
        for page in pages {
            page.deinitialize().deallocate()
        }
        for i in 0..<currentOffset {
            currentPage.deinitializeElement(at: i)
        }
        currentPage.deallocate()
    }

    /// Starts a new fresh page.
    private func startNewPage() {
        pages.append(currentPage)
        // TODO: Should we grow the page size?
        let page = UnsafeMutableBufferPointer<T>.allocate(capacity: currentPageSize)
        currentPage = page
        currentOffset = 0
    }

    /// Allocates a new value with the given `value` and returns a pointer to it.
    ///
    /// - Parameter value: The value to initialize the allocated memory with.
    /// - Returns: A pointer to the allocated memory.
    func allocate(initializing value: T) -> UnsafeMutablePointer<T> {
        let pointer = allocate()
        pointer.initialize(to: value)
        return pointer
    }

    /// Allocates a new value and returns a pointer to it.
    ///
    /// - Note: The allocated memory must be initialized before
    ///   the allocator is deallocated.
    ///
    /// - Returns: An uninitialized pointer of type `T`.
    func allocate() -> UnsafeMutablePointer<T> {
        if currentOffset == currentPageSize {
            startNewPage()
        }
        let pointer = currentPage.baseAddress!.advanced(by: currentOffset)
        currentOffset += 1
        return pointer
    }
}

protocol ValidatableEntity {
    /// Create an error for an out-of-bounds access to the entity.
    static func createOutOfBoundsError(index: Int, count: Int) -> any Error
}


/// A simple bump allocator for immutable arrays with various element types.
fileprivate class ImmutableArrayAllocator {
    private var arrayBuffers: [UnsafeMutableRawPointer] = []

    /// Allocates a buffer for an immutable array of `T` with the given `count`.
    ///
    /// - Note: The element type `T` must be a trivial type.
    func allocate<T>(count: Int) -> UnsafeMutableBufferPointer<T> {
        // We only support trivial types for now. Otherwise, we have to track the element type
        // until the deallocation of this allocator.
        assert(_isPOD(T.self), "ImmutableArrayAllocator only supports trivial element types.")
        let buffer = UnsafeMutableBufferPointer<T>.allocate(capacity: count)
        // If count is zero, don't manage such empty buffer.
        if let baseAddress = buffer.baseAddress {
            arrayBuffers.append(baseAddress)
        }
        return buffer
    }

    deinit {
        for buffer in arrayBuffers {
            buffer.deallocate()
        }
    }
}

/// An immutable array allocated by a bump allocator.
struct ImmutableArray<T> {
    private let buffer: UnsafeBufferPointer<T>

    /// Initializes an immutable array with the given `count` and `initialize` closure.
    ///
    /// - Parameters:
    ///   - allocator: An allocator to allocate the buffer. The returned array should not outlive the allocator.
    ///   - count: The number of elements in the array.
    ///   - initialize: A closure to initialize the buffer.
    fileprivate init(allocator: ImmutableArrayAllocator, count: Int, initialize: (UnsafeMutableBufferPointer<T>) throws -> Void) rethrows {
        let mutable: UnsafeMutableBufferPointer<T> = allocator.allocate(count: count)
        try initialize(mutable)
        buffer = UnsafeBufferPointer(mutable)
    }

    /// Accesses the element at the specified position.
    subscript(index: Int) -> T {
        buffer[index]
    }

    /// Accesses the element at the specified position, with bounds checking.
    subscript(validating index: Int) -> T where T: ValidatableEntity {
        get throws {
            return try self[validating: index, T.createOutOfBoundsError]
        }
    }

    /// Accesses the element at the specified position, with bounds checking
    /// and a custom error creation function.
    subscript(validating index: Int, createError: (_ index: Int, _ count: Int) -> any Error) -> T {
        get throws {
            guard index >= 0 && index < buffer.count else {
                throw createError(index, buffer.count)
            }
            return buffer[index]
        }
    }

    /// The first element of the array.
    var first: T? { buffer.first }

    /// The number of elements in the array.
    var count: Int { buffer.count }
}

extension ImmutableArray: Sequence {
    typealias Element = T
    typealias Iterator = UnsafeBufferPointer<T>.Iterator

    func makeIterator() -> Iterator {
        buffer.makeIterator()
    }
}


/// A type that can be interned into a unique identifier.
/// Used for efficient equality comparison.
protocol Internable {
    /// Storage representation of an interned value.
    associatedtype Offset: UnsignedInteger
}

/// An interned value of type `T`.
/// Two interned values should be equal if their corresponding `T` values are equal.
struct Interned<T: Internable>: Equatable, Hashable {
    let id: T.Offset
}

/// A deduplicating interner for values of type `Item`.
class Interner<Item: Hashable & Internable> {
    private var itemByIntern: [Item]
    private var internByItem: [Item: Interned<Item>]

    init() {
        itemByIntern = []
        internByItem = [:]
    }

    /// Interns the given `item` and returns an interned value.
    /// If the item is already interned, returns the existing interned value.
    func intern(_ item: Item) -> Interned<Item> {
        if let interned = internByItem[item] {
            return interned
        }
        let id = itemByIntern.count
        itemByIntern.append(item)
        let newInterned = Interned<Item>(id: Item.Offset(id))
        internByItem[item] = newInterned
        return newInterned
    }

    /// Resolves the given `interned` value to the original value.
    func resolve(_ interned: Interned<Item>) -> Item {
        return itemByIntern[Int(interned.id)]
    }
}

/// A function type is internable for efficient equality comparison.
/// Usually used for signature checking at indirect calls.
extension FunctionType: Internable {
    typealias Offset = UInt32
}

typealias InternedFuncType = Interned<FunctionType>

/// A bump allocator associated with a ``Store``.
/// An allocator should live as long as the store it is associated with.
class StoreAllocator {
    private var instances: BumpAllocator<InstanceEntity>
    private var functions: BumpAllocator<WasmFunctionEntity>
    private var hostFunctions: BumpAllocator<HostFunctionEntity>
    private var tables: BumpAllocator<TableEntity>
    private var memories: BumpAllocator<MemoryEntity>
    private var globals: BumpAllocator<GlobalEntity>
    private var elements: BumpAllocator<ElementSegmentEntity>
    private var datas: BumpAllocator<DataSegmentEntity>
    private var codes: BumpAllocator<Code>
    private let arrayAllocator: ImmutableArrayAllocator
    let iseqAllocator: ISeqAllocator

    /// Function type interner shared across stores associated with the same `Runtime`.
    let funcTypeInterner: Interner<FunctionType>

    init(funcTypeInterner: Interner<FunctionType>) {
        instances = BumpAllocator(initialCapacity: 2)
        functions = BumpAllocator(initialCapacity: 64)
        hostFunctions = BumpAllocator(initialCapacity: 32)
        codes = BumpAllocator(initialCapacity: 64)
        tables = BumpAllocator(initialCapacity: 2)
        memories = BumpAllocator(initialCapacity: 2)
        globals = BumpAllocator(initialCapacity: 256)
        elements = BumpAllocator(initialCapacity: 2)
        datas = BumpAllocator(initialCapacity: 64)
        arrayAllocator = ImmutableArrayAllocator()
        iseqAllocator = ISeqAllocator()
        self.funcTypeInterner = funcTypeInterner
    }
}

extension StoreAllocator: Equatable {
    static func == (lhs: StoreAllocator, rhs: StoreAllocator) -> Bool {
        /// Use reference identity for equality comparison.
        return lhs === rhs
    }
}


extension StoreAllocator {
    /// > Note:
    /// <https://webassembly.github.io/spec/core/exec/modules.html#alloc-module>
    func allocate(
        module: Module,
        runtime: Runtime,
        externalValues: [ExternalValue]
    ) throws -> InternalInstance {
        let resourceLimiter = runtime.store.resourceLimiter
        // Step 1 of module allocation algorithm, according to Wasm 2.0 spec.

        let types = module.types
        // Uninitialized instance
        let instancePointer = instances.allocate()
        let instanceHandle = InternalInstance(unsafe: instancePointer)
        var importedFunctions: [InternalFunction] = []
        var importedTables: [InternalTable] = []
        var importedMemories: [InternalMemory] = []
        var importedGlobals: [InternalGlobal] = []

        // External values imported in this module should be included in corresponding index spaces before definitions
        // local to to the module are added.
        for external in externalValues {
            switch external {
            case let .function(function):
                // Step 14.
                importedFunctions.append(function.handle)
            case let .table(table):
                // Step 15.
                importedTables.append(table.handle)
            case let .memory(memory):
                // Step 16.
                importedMemories.append(memory.handle)
            case let .global(global):
                // Step 17.
                importedGlobals.append(global.handle)
            }
        }

        func allocateEntities<EntityHandle, Internals: Collection>(
            imports: [EntityHandle],
            internals: Internals, allocateHandle: (Internals.Element, Int) throws -> EntityHandle
        ) rethrows -> ImmutableArray<EntityHandle> {
            return try ImmutableArray<EntityHandle>(allocator: arrayAllocator, count: imports.count + internals.count) { buffer in
                for (index, importedEntity) in imports.enumerated() {
                    buffer.initializeElement(at: index, to: importedEntity)
                }
                for (index, internalEntity) in internals.enumerated() {
                    let allocated = try allocateHandle(internalEntity, index)
                    buffer.initializeElement(at: imports.count + index, to: allocated)
                }
            }
        }

        // Step 2.
        let functions = allocateEntities(
            imports: importedFunctions,
            internals: module.functions,
            allocateHandle: { f, _ in
                allocate(function: f, instance: instanceHandle, runtime: runtime)
            }
        )

        // Step 3.
        let tables = try allocateEntities(
            imports: importedTables,
            internals: module.internalTables,
            allocateHandle: { t, _ in try allocate(tableType: t, resourceLimiter: resourceLimiter) }
        )

        // Step 4.
        let memories = try allocateEntities(
            imports: importedMemories,
            internals: module.internalMemories,
            allocateHandle: { m, _ in try allocate(memoryType: m, resourceLimiter: resourceLimiter) }
        )

        // Step 5.
        var constEvalContext = ConstEvaluationContext(
            functions: functions,
            globals: importedGlobals.map(\.value)
        )
        let globals = try allocateEntities(
            imports: importedGlobals,
            internals: module.globals,
            allocateHandle: { global, i in
                let initialValue = try global.initializer.evaluate(context: constEvalContext)
                constEvalContext.globals.append(initialValue)
                return allocate(globalType: global.type, initialValue: initialValue)
            }
        )

        // Step 6.
        let elements = try ImmutableArray<InternalElementSegment>(allocator: arrayAllocator, count: module.elements.count) { buffer in
            for (index, element) in module.elements.enumerated() {
                let references: [Reference]
                switch element.mode {
                case .active, .declarative:
                    // active & declarative segments are unavailable at runtime
                    references = []
                case .passive:
                    references = try element.evaluateInits(context: constEvalContext)
                }
                let handle = allocate(elementType: element.type, references: references)
                buffer.initializeElement(at: index, to: handle)
            }
        }

        // Step 13.
        let dataSegments = ImmutableArray<InternalDataSegment>(allocator: arrayAllocator, count: module.data.count) { buffer in
            for (index, datum) in module.data.enumerated() {
                let segment: InternalDataSegment
                switch datum {
                case let .passive(bytes):
                    segment = allocate(bytes: bytes)
                case .active:
                    // Active segments are copied into memories while instantiation
                    // They are semantically dropped after instantiation, so we don't
                    // need them at runtime
                    segment = allocate(bytes: [])
                }
                buffer.initializeElement(at: index, to: segment)
            }
        }


        func createExportValue(_ export: WasmParser.Export) throws -> InternalExternalValue {
            func createErrorFactory(_ kind: String) -> (_ index: Int, _ count: Int) -> any Error {
                return { index, count in
                    InstantiationError.exportIndexOutOfBounds(kind: kind, index: index, count: count)
                }
            }
            switch export.descriptor {
            case let .function(index):
                let handle = try functions[validating: Int(index), createErrorFactory("function")]
                return .function(handle)
            case let .table(index):
                let handle = try tables[validating: Int(index), createErrorFactory("table")]
                return .table(handle)
            case let .memory(index):
                let handle = try memories[validating: Int(index), createErrorFactory("memory")]
                return .memory(handle)
            case let .global(index):
                let handle = try globals[validating: Int(index), createErrorFactory("global")]
                return .global(handle)
            }
        }

        let exports: [String: InternalExternalValue] = try module.exports.reduce(into: [:]) { result, export in
            result[export.name] = try createExportValue(export)
        }

        // Steps 20-21.
        let instanceEntity = InstanceEntity(
            types: types,
            functions: functions,
            tables: tables,
            memories: memories,
            globals: globals,
            elementSegments: elements,
            dataSegments: dataSegments,
            exports: exports,
            features: module.features,
            hasDataCount: module.hasDataCount
        )
        instancePointer.initialize(to: instanceEntity)
        return instanceHandle
    }

    /// > Note:
    /// <https://webassembly.github.io/spec/core/exec/modules.html#alloc-func>
    /// TODO: Mark as private
    func allocate(
        function: GuestFunction,
        instance: InternalInstance,
        runtime: Runtime
    ) -> InternalFunction {
        let code = InternalUncompiledCode(unsafe: codes.allocate(initializing: function.code))
        let pointer = functions.allocate(
            initializing: WasmFunctionEntity(
                type: runtime.internType(function.type),
                code: code,
                instance: instance
            )
        )
        return InternalFunction.wasm(EntityHandle(unsafe: pointer))
    }

    func allocate(hostFunction: HostFunction, runtime: Runtime) -> InternalFunction {
        let pointer = hostFunctions.allocate(
            initializing: HostFunctionEntity(
                type: runtime.internType(hostFunction.type),
                implementation: hostFunction.implementation
            )
        )
        return InternalFunction.host(EntityHandle(unsafe: pointer))
    }

    /// > Note:
    /// <https://webassembly.github.io/spec/core/exec/modules.html#alloc-table>
    private func allocate(tableType: TableType, resourceLimiter: any ResourceLimiter) throws -> InternalTable {
        let pointer = try tables.allocate(initializing: TableEntity(tableType, resourceLimiter: resourceLimiter))
        return InternalTable(unsafe: pointer)
    }

    /// > Note:
    /// <https://webassembly.github.io/spec/core/exec/modules.html#alloc-mem>
    func allocate(memoryType: MemoryType, resourceLimiter: any ResourceLimiter) throws -> InternalMemory {
        let pointer = try memories.allocate(initializing: MemoryEntity(memoryType, resourceLimiter: resourceLimiter))
        return InternalMemory(unsafe: pointer)
    }

    /// > Note:
    /// <https://webassembly.github.io/spec/core/exec/modules.html#alloc-global>
    func allocate(globalType: GlobalType, initialValue: Value) -> InternalGlobal {
        let pointer = globals.allocate(initializing: GlobalEntity(globalType: globalType, initialValue: initialValue))
        return InternalGlobal(unsafe: pointer)
    }

    /// > Note:
    /// <https://webassembly.github.io/spec/core/exec/modules.html#element-segments>
    private func allocate(elementType: ReferenceType, references: [Reference]) -> InternalElementSegment {
        let pointer = elements.allocate(initializing: ElementSegmentEntity(type: elementType, references: references))
        return InternalElementSegment(unsafe: pointer)
    }

    /// > Note:
    /// <https://webassembly.github.io/spec/core/exec/modules.html#data-segments>
    private func allocate(bytes: ArraySlice<UInt8>) -> InternalDataSegment {
        let pointer = datas.allocate(initializing: DataSegmentEntity(data: bytes))
        return EntityHandle(unsafe: pointer)
    }
}
